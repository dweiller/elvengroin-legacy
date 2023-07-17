const std = @import("std");
const math = std.math;
const ecs = @import("zflecs");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const gfx_d3d12 = @import("../gfx_d3d12.zig");
const zd3d12 = @import("zd3d12");

const ecsu = @import("../../flecs_util/flecs_util.zig");
const fd = @import("../flecs_data.zig");
const IdLocal = @import("../variant.zig").IdLocal;
const input = @import("../input.zig");
const config = @import("../config.zig");

const SystemState = struct {
    allocator: std.mem.Allocator,
    ecs_world: *ecs.world_t,
    sys: ecs.entity_t,

    gctx: *zd3d12.GraphicsContext,
    query_camera: ecsu.Query,
    query_transform: ecsu.Query,

    frame_data: *input.FrameData,
    switch_pressed: bool = false,
    active_index: u32 = 1,
};

pub fn create(name: IdLocal, allocator: std.mem.Allocator, gfxstate: *gfx_d3d12.D3D12State, ecs_world: *ecs.world_t, frame_data: *input.FrameData) !*SystemState {
    var query_builder = ecsu.QueryBuilder.init.init(ecs_world.*);
    _ = query_builder
        .with(fd.Camera)
        .with(fd.Transform);
    var query_camera = query_builder.buildQuery();

    var query_builder_transform = ecsu.QueryBuilder.init.init(ecs_world.*);
    _ = query_builder_transform
        .with(fd.Transform)
        .optional(fd.Forward)
        .withReadonly(fd.Position)
        .withReadonly(fd.EulerRotation)
        .withReadonly(fd.Scale)
        .withReadonly(fd.Dynamic);

    var query_builder_transform_parent_term = query_builder_transform.manualTerm();
    query_builder_transform_parent_term.id = ecs_world.componentId(fd.Transform);
    query_builder_transform_parent_term.inout = .ecs_in;
    query_builder_transform_parent_term.oper = .ecs_optional;
    query_builder_transform_parent_term.src.flags = ecs.Parent | ecs.Cascade;
    var query_transform = query_builder_transform.buildQuery();

    //     var edesc = ecs.system_desc_t{};
    //     edesc.id = 0;
    //     edesc.name = name.toCString();
    //     edesc.add[0] = ecs.ecs_pair(ecs.EcsDependsOn, ecs.EcsOnUpdate);
    //     edesc.add[1] = ecs.EcsOnUpdate;

    //     // var system_desc =  ecs.system_desc_t{};
    //     // system_desc.entity = ecs.ecs_entity_init(ecs_world, &edesc);
    //     // system_desc.query.filter = ecsu.meta.generateFilterDesc(self, Components);
    //     // system_desc.callback = dummyFn;
    //     // system_desc.run = wrapSystemFn(Components, action);
    //     // system_desc.ctx = params.ctx;
    //     // return ecs.ecs_system_init(self.world, &system_desc);
    // var sys = ecs.SYSTEM(ecs_world, name.toCString(), ecs.EcsOnUpdate, fd.NOCOMP, update, .{ .ctx = state });

    var state = allocator.create(SystemState) catch unreachable;

    var sys = ecsu.World.init(ecs_world).newWrappedRunSystem(name.toCString(), .on_update, fd.NOCOMP, update, .{ .ctx = state });
    state.* = .{
        .allocator = allocator,
        .ecs_world = ecs_world,
        .sys = sys,
        .gctx = &gfxstate.gctx,
        .query_camera = query_camera,
        .query_transform = query_transform,
        .frame_data = frame_data,
    };

    ecs_world.observer(ObserverCallback, .on_set, state);

    return state;
}

pub fn destroy(state: *SystemState) void {
    state.query_camera.deinit();
    state.query_transform.deinit();
    state.allocator.destroy(state);
}

fn update(iter: *ecsu.Iterator(fd.NOCOMP)) void {
    var state: *SystemState = @ptrCast(@alignCast(iter.iter.ctx));
    updateCameraSwitch(state);
    updateTransformHierarchy(state);
    updateCameraMatrices(state);
    updateCameraFrustum(state);
}

fn updateTransformHierarchy(state: *SystemState) void {
    var entity_iter_transform = state.query_transform.iterator(struct {
        transform: *fd.Transform,
        fwd: ?*fd.Forward,
        pos: *const fd.Position,
        rot: *const fd.EulerRotation,
        scale: *const fd.Scale,
        dynamic: *const fd.Dynamic,
        parent_transform: ?*const fd.Transform,
    });

    while (entity_iter_transform.next()) |comps| {
        const z_scale_matrix = zm.scaling(comps.scale.x, comps.scale.y, comps.scale.z);
        const z_rot_matrix = zm.matFromRollPitchYaw(comps.rot.pitch, comps.rot.yaw, comps.rot.roll);
        const z_translate_matrix = zm.translation(comps.pos.x, comps.pos.y, comps.pos.z);
        const z_sr_matrix = zm.mul(z_scale_matrix, z_rot_matrix);
        const z_srt_matrix = zm.mul(z_sr_matrix, z_translate_matrix);

        const z_world_matrix = blk: {
            if (comps.parent_transform) |parent_transform| {
                const z_parent_matrix = zm.loadMat43(parent_transform.matrix[0..]);
                const z_world_matrix = zm.mul(z_srt_matrix, z_parent_matrix);
                break :blk z_world_matrix;
            } else {
                break :blk z_srt_matrix;
            }
        };

        if (comps.fwd) |fwd| {
            const z_fwd = zm.util.getAxisZ(z_world_matrix);
            zm.storeArr3(fwd.*.elems(), z_fwd);
        }
        zm.storeMat43(&comps.transform.matrix, z_world_matrix);
    }
}

fn updateCameraMatrices(state: *SystemState) void {
    const gctx = state.gctx;
    const framebuffer_width = gctx.viewport_width;
    const framebuffer_height = gctx.viewport_height;

    var entity_iter = state.query_camera.iterator(struct {
        camera: *fd.Camera,
        transform: *fd.Transform,
    });

    while (entity_iter.next()) |comps| {
        var cam = comps.camera;
        if (!cam.active) {
            continue;
        }

        const z_transform = zm.loadMat43(comps.transform.matrix[0..]);
        var z_forward = zm.util.getAxisZ(z_transform);
        var z_pos = zm.util.getTranslationVec(z_transform);

        const z_view = zm.lookToLh(
            z_pos,
            z_forward,
            zm.f32x4(0.0, 1.0, 0.0, 0.0),
        );

        const z_projection =
            zm.perspectiveFovLh(
            0.25 * math.pi,
            @as(f32, @floatFromInt(framebuffer_width)) / @as(f32, @floatFromInt(framebuffer_height)),
            comps.camera.far,
            comps.camera.near,
        );

        zm.storeMat(cam.view[0..], z_view);
        zm.storeMat(cam.projection[0..], z_projection);
        zm.storeMat(cam.view_projection[0..], zm.mul(z_view, z_projection));
    }
}

fn updateCameraFrustum(state: *SystemState) void {
    var entity_iter = state.query_camera.iterator(struct {
        camera: *fd.Camera,
        transform: *fd.Transform,
    });

    while (entity_iter.next()) |comps| {
        var cam = comps.camera;
        if (!cam.active) {
            continue;
        }

        // TODO(gmodarelli): Check if renderer is frozen
        cam.calculateFrusumPlanes();
    }
}

fn updateCameraSwitch(state: *SystemState) void {
    if (!state.frame_data.just_pressed(config.input_camera_switch)) {
        return;
    }

    state.active_index = 1 - state.active_index;

    var builder = ecsu.QueryBuilder.init.init(state.ecs_world.*);
    _ = builder
        .with(fd.Input)
        .optional(fd.Camera);

    var filter = builder.buildFilter();
    defer filter.deinit();

    var entity_iter = filter.iterator(struct {
        input: *fd.Input,
        cam: ?*fd.Camera,
    });
    while (entity_iter.next()) |comps| {
        var active = false;
        if (comps.input.index == state.active_index) {
            active = true;
        }

        comps.input.active = active;
        if (comps.cam) |cam| {
            cam.active = active;
        }
    }
}

const ObserverCallback = struct {
    comp: *const fd.CICamera,

    pub const name = "CICamera";
    pub const run = onSetCICamera;
};

fn onSetCICamera(it: *ecsu.Iterator(ObserverCallback)) void {
    // var observer = @ptrCast(*ecs.observer_t, @alignCast(@alignOf(ecs.observer_t), it.iter.ctx));
    // var state : *SystemState = @ptrCast(@alignCast(observer.*.ctx));
    while (it.next()) |_| {
        const ci_ptr = ecs.ecs_field_w_size(it.iter, @sizeOf(fd.CICamera), @as(i32, @intCast(it.index))).?;
        var ci = @as(*fd.CICamera, @ptrCast(@alignCast(ci_ptr)));
        const ent = it.entity();
        ent.remove(fd.CICamera);
        ent.set(fd.Camera{
            .far = ci.far,
            .near = ci.near,
            .window = ci.window,
            .active = ci.active,
            .class = ci.class,
        });
        ent.set(fd.Forward{ .x = 0, .y = 0, .z = 1 });
    }
}
