const std = @import("std");
const math = std.math;
const ecs = @import("zflecs");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const gfx_d3d12 = @import("../gfx_d3d12.zig");
const zd3d12 = @import("zd3d12");

const ecsu = @import("../flecs_util/flecs_util.zig");
const fd = @import("../flecs_data.zig");
const IdLocal = @import("../variant.zig").IdLocal;
const input = @import("../input.zig");
const config = @import("../config.zig");

const SystemState = struct {
    allocator: std.mem.Allocator,
    ecsu_world: ecsu.World,
    sys: ecs.entity_t,

    gctx: *zd3d12.GraphicsContext,
    query_camera: ecsu.Query,
    query_transform: ecsu.Query,

    frame_data: *input.FrameData,
    switch_pressed: bool = false,
    active_index: u32 = 1,
};

pub fn create(name: IdLocal, allocator: std.mem.Allocator, gfxstate: *gfx_d3d12.D3D12State, ecsu_world: ecsu.World, frame_data: *input.FrameData) !*SystemState {
    var query_builder = ecsu.QueryBuilder.init(ecsu_world);
    _ = query_builder
        .with(fd.Camera)
        .with(fd.Transform);
    var query_camera = query_builder.buildQuery();

    var query_builder_transform = ecsu.QueryBuilder.init(ecsu_world);
    _ = query_builder_transform
        .with(fd.Transform)
        .optional(fd.Forward)
        .optional(fd.Velocity)
        .withReadonly(fd.Position)
        .withReadonly(fd.Rotation)
        .withReadonly(fd.Scale)
        .withReadonly(fd.Dynamic);

    var query_builder_transform_parent_term = query_builder_transform.manualTerm();
    query_builder_transform_parent_term.id = ecsu_world.componentId(fd.Transform);
    query_builder_transform_parent_term.inout = .In;
    query_builder_transform_parent_term.oper = .Optional;
    query_builder_transform_parent_term.src.flags = ecs.Parent | ecs.Cascade;
    var query_transform = query_builder_transform.buildQuery();

    //     var edesc = ecs.system_desc_t{};
    //     edesc.id = 0;
    //     edesc.name = name.toCString();
    //     edesc.add[0] = ecs.pair(ecs.DependsOn, ecs.OnUpdate);
    //     edesc.add[1] = ecs.OnUpdate;

    //     // var system_desc =  ecs.system_desc_t{};
    //     // system_desc.entity = ecs.entity_init(ecsu_world, &edesc);
    //     // system_desc.query.filter = ecsu.meta.generateFilterDesc(self, Components);
    //     // system_desc.callback = dummyFn;
    //     // system_desc.run = wrapSystemFn(Components, action);
    //     // system_desc.ctx = params.ctx;
    //     // return ecs.system_init(self.world, &system_desc);
    // var sys = ecs.SYSTEM(ecsu_world, name.toCString(), ecs.OnUpdate, fd.NOCOMP, update, .{ .ctx = state });

    var state = allocator.create(SystemState) catch unreachable;

    var sys = ecsu_world.newWrappedRunSystem(name.toCString(), ecs.OnUpdate, fd.NOCOMP, update, .{ .ctx = state });
    state.* = .{
        .allocator = allocator,
        .ecsu_world = ecsu_world,
        .sys = sys,
        .gctx = &gfxstate.gctx,
        .query_camera = query_camera,
        .query_transform = query_transform,
        .frame_data = frame_data,
    };

    ecsu_world.observer(ObserverCallback, ecs.OnSet, state);

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
    updateTransformHierarchy(state, iter.iter.delta_time);
    updateCameraMatrices(state);
    updateCameraFrustum(state);
}

fn updateTransformHierarchy(state: *SystemState, dt: f32) void {
    var entity_iter_transform = state.query_transform.iterator(struct {
        transform: *fd.Transform,
        fwd: ?*fd.Forward,
        vel: ?*fd.Velocity,
        pos: *const fd.Position,
        rot: *const fd.Rotation,
        scale: *const fd.Scale,
        dynamic: *const fd.Dynamic,
        parent_transform: ?*const fd.Transform,
    });

    const is_actual_frame = dt > 0.00001;
    const dt4: zm.F32x4 = @splat(dt);

    while (entity_iter_transform.next()) |comps| {
        const z_scale_matrix = zm.scaling(comps.scale.x, comps.scale.y, comps.scale.z);
        const z_rot_matrix = zm.matFromQuat(comps.rot.asZM());
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

        if (is_actual_frame) {
            if (comps.vel) |vel| {
                const pos_prev = zm.loadArr3(comps.transform.getPos00());
                const pos_curr = zm.util.getTranslationVec(z_world_matrix);
                zm.storeArr3(vel.elems(), (pos_curr - pos_prev) / dt4);
            }
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
            cam.fov,
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

    var builder = ecsu.QueryBuilder.init(state.ecsu_world);
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
        const ci_ptr = ecs.field_w_size(it.iter, @sizeOf(fd.CICamera), @as(i32, @intCast(it.index))).?;
        var ci = @as(*fd.CICamera, @ptrCast(@alignCast(ci_ptr)));
        const ent = ecsu.Entity.init(it.iter.world, it.entity());
        ent.remove(fd.CICamera);
        ent.set(fd.Camera{
            .far = ci.far,
            .near = ci.near,
            .fov = 0.25 * std.math.pi,
            .window = ci.window,
            .active = ci.active,
            .class = ci.class,
        });
        ent.set(fd.Forward{ .x = 0, .y = 0, .z = 1 });
    }
}
