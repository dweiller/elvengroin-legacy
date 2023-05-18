const std = @import("std");
const math = std.math;
const flecs = @import("flecs");
const zm = @import("zmath");
const zphy = @import("zphysics");

const fd = @import("../flecs_data.zig");
const fr = @import("../flecs_relation.zig");
const IdLocal = @import("../variant.zig").IdLocal;
const world_patch_manager = @import("../worldpatch/world_patch_manager.zig");
const tides_math = @import("../core/math.zig");
const util = @import("../util.zig");
const config = @import("../config.zig");
const input = @import("../input.zig");
const EventManager = @import("../core/event_manager.zig").EventManager;

const SystemState = struct {
    flecs_sys: flecs.EntityId,
    allocator: std.mem.Allocator,
    physics_world: *zphy.PhysicsSystem,
    flecs_world: *flecs.World,
    frame_data: *input.FrameData,

    comp_query_interactor: flecs.Query,
};

pub fn create(name: IdLocal, ctx: util.Context) !*SystemState {
    const allocator = ctx.getConst(config.allocator.hash, std.mem.Allocator).*;
    const flecs_world = ctx.get(config.flecs_world.hash, flecs.World);
    const physics_world = ctx.get(config.physics_world.hash, zphy.PhysicsSystem);
    const frame_data = ctx.get(config.input_frame_data.hash, input.FrameData);
    const event_manager = ctx.get(config.event_manager.hash, EventManager);

    var query_builder_interactor = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_interactor
        .with(fd.Interactor)
        .with(fd.Transform);
    const comp_query_interactor = query_builder_interactor.buildQuery();

    var system = allocator.create(SystemState) catch unreachable;
    var flecs_sys = flecs_world.newWrappedRunSystem(name.toCString(), .on_update, fd.NOCOMP, update, .{ .ctx = system });
    system.* = .{
        .flecs_sys = flecs_sys,
        .allocator = allocator,
        .flecs_world = flecs_world,
        .physics_world = physics_world,
        .frame_data = frame_data,
        .comp_query_interactor = comp_query_interactor,
    };

    // flecs_world.observer(OnCollideObserverCallback, fd.PhysicsBody, system);
    // flecs_world.observer(OnCollideObserverCallback, config.events.onCollisionEvent(flecs_world.world), system);
    event_manager.registerListener(config.events.frame_collisions_id, onEventFrameCollisions, system);

    // initStateData(system);
    return system;
}

pub fn destroy(system: *SystemState) void {
    system.comp_query_interactor.deinit();
    system.allocator.destroy(system);
}

fn update(iter: *flecs.Iterator(fd.NOCOMP)) void {
    var system = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), iter.iter.ctx));
    updateInteractors(system, iter.iter.delta_time);
}

fn updateInteractors(system: *SystemState, dt: f32) void {
    _ = dt;
    var entity_iter = system.comp_query_interactor.iterator(struct {
        Interactor: *fd.Interactor,
        transform: *fd.Transform,
    });

    var arena_state = std.heap.ArenaAllocator.init(system.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = arena;

    const wielded_use_primary_held = system.frame_data.held(config.input_wielded_use_primary);
    const wielded_use_primary_released = system.frame_data.just_released(config.input_wielded_use_primary);
    while (entity_iter.next()) |comps| {
        var interactor_comp = comps.Interactor;

        const item_ent = flecs.Entity.init(system.flecs_world.world, interactor_comp.wielded_item_ent_id);
        var weapon_comp = item_ent.getMut(fd.ProjectileWeapon).?;

        if (weapon_comp.chambered_projectile == 0) {
            // Load new projectile
            var proj_ent = system.flecs_world.newEntity();
            // proj_ent.setName("arrow");
            proj_ent.set(fd.Position{ .x = -0.03, .y = 0, .z = -0.5 });
            proj_ent.set(fd.EulerRotation{});
            proj_ent.set(fd.Scale.createScalar(1));
            proj_ent.set(fd.Transform.initFromPosition(.{ .x = -0.03, .y = 0, .z = -0.5 }));
            proj_ent.set(fd.Forward{});
            proj_ent.set(fd.Dynamic{});
            proj_ent.set(fd.Projectile{});
            proj_ent.set(fd.CIShapeMeshInstance{
                .id = IdLocal.id64("arrow"),
                .basecolor_roughness = .{ .r = 1.0, .g = 1.0, .b = 1.0, .roughness = 1.0 },
            });
            proj_ent.childOf(item_ent);
            weapon_comp.chambered_projectile = proj_ent.id;
            return;
        }

        var proj_ent = flecs.Entity.init(system.flecs_world.world, weapon_comp.chambered_projectile);
        var item_rotation = item_ent.getMut(fd.EulerRotation).?;
        const item_transform = item_ent.get(fd.Transform).?;
        const target_roll: f32 = if (wielded_use_primary_held) -1 else 0;
        item_rotation.roll = zm.lerpV(item_rotation.roll, target_roll, 0.1);
        if (wielded_use_primary_released) {
            // Shoot arrow
            // std.debug.print("RELEASE\n", .{});
            const charge = weapon_comp.charge;
            weapon_comp.charge = 0;

            // state.physics_world.optimizeBroadPhase();
            weapon_comp.chambered_projectile = 0;
            proj_ent.removePair(flecs.c.Constants.EcsChildOf, item_ent);

            const body_interface = system.physics_world.getBodyInterfaceMut();

            const proj_transform = proj_ent.get(fd.Transform).?;
            const proj_pos_world = proj_transform.getPos00();
            const proj_rot_world = proj_transform.getRotPitchRollYaw();
            _ = proj_rot_world;

            const proj_shape_settings = zphy.BoxShapeSettings.create(.{ 0.15, 0.15, 1.0 }) catch unreachable;
            defer proj_shape_settings.release();

            const proj_shape = proj_shape_settings.createShape() catch unreachable;
            defer proj_shape.release();

            const proj_body_id = body_interface.createAndAddBody(.{
                .position = .{ proj_pos_world[0], proj_pos_world[1], proj_pos_world[2], 0 },
                .rotation = .{ 0, 0, 0, 1 },
                .shape = proj_shape,
                .motion_type = .dynamic,
                .object_layer = config.object_layers.moving,
                .motion_quality = .linear_cast,
                .user_data = proj_ent.id,
            }, .activate) catch unreachable;

            //  Assign to flecs component
            proj_ent.set(fd.PhysicsBody{ .body_id = proj_body_id });

            // Send it flying
            const world_transform_z = zm.loadMat43(&item_transform.matrix);
            const forward_z = zm.util.getAxisZ(world_transform_z);
            const velocity_z = forward_z * zm.f32x4s(10 + charge * 20);
            var velocity: [3]f32 = undefined;
            zm.storeArr3(&velocity, velocity_z);
            body_interface.setLinearVelocity(proj_body_id, velocity);
        } else if (wielded_use_primary_held) {
            // Pull string
            var proj_pos = proj_ent.getMut(fd.Position).?;

            proj_pos.z = zm.lerpV(proj_pos.z, -0.8, 0.01);
            weapon_comp.charge = zm.mapLinearV(proj_pos.z, -0.4, -0.8, 0, 1);
        } else {
            // Relax string
            var proj_pos = proj_ent.getMut(fd.Position).?;
            proj_pos.z = zm.lerpV(proj_pos.z, -0.4, 0.1);
        }
    }
}

//  ██████╗ █████╗ ██╗     ██╗     ██████╗  █████╗  ██████╗██╗  ██╗███████╗
// ██╔════╝██╔══██╗██║     ██║     ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██╔════╝
// ██║     ███████║██║     ██║     ██████╔╝███████║██║     █████╔╝ ███████╗
// ██║     ██╔══██║██║     ██║     ██╔══██╗██╔══██║██║     ██╔═██╗ ╚════██║
// ╚██████╗██║  ██║███████╗███████╗██████╔╝██║  ██║╚██████╗██║  ██╗███████║
//  ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝

fn onEventFrameCollisions(ctx: *anyopaque, event_id: u64, event_data: *anyopaque) void {
    _ = event_id;
    var system = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), ctx));
    const frame_collisions_data = @ptrCast(*config.events.FrameCollisionsData, @alignCast(@alignOf(config.events.FrameCollisionsData), event_data));
    for (frame_collisions_data.contacts) |contact| {
        const ent1 = flecs.Entity.init(system.flecs_world.world, contact.ent1);
        _ = ent1;
        const ent2 = flecs.Entity.init(system.flecs_world.world, contact.ent2);
        // if (ent1.has(fd.Projectile)) {
        // ent1.remove(fd.PhysicsBody);
        // }
        // if (ent2.has(fd.Projectile)) {
        ent2.remove(fd.PhysicsBody);
        // }
    }
}
