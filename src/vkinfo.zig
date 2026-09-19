//! Dumps the Vulkan extensions/layers/devices the webOS TV's Mali ICD offers.
//!   zig build-exe vkinfo.zig -target arm-linux-gnueabi.2.31 -lc -O ReleaseSmall
//!
//! There is no libvulkan.so.1 (Khronos loader) on the device, only the ICD itself
//! at /usr/lib/libmali.so, registered in /usr/share/vulkan/icd.d/mali.json. Since
//! we use no WSI surface extension, the loader buys us nothing: dlopen the ICD and
//! use vk_icdGetInstanceProcAddr as vkGetInstanceProcAddr directly.
const std = @import("std");
const c = std.c;

const VK_SUCCESS = 0;
const API_1_3 = (@as(u32, 1) << 22) | (@as(u32, 3) << 12);

const ExtensionProperties = extern struct { name: [256]u8, spec_version: u32 };
const LayerProperties = extern struct { name: [256]u8, spec_version: u32, impl_version: u32, description: [256]u8 };

const ApplicationInfo = extern struct {
    s_type: u32 = 0,
    p_next: ?*const anyopaque = null,
    app_name: ?[*:0]const u8 = null,
    app_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = 0,
};

const InstanceCreateInfo = extern struct {
    s_type: u32 = 1,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    app_info: ?*const ApplicationInfo = null,
    layer_count: u32 = 0,
    layer_names: ?[*]const [*:0]const u8 = null,
    ext_count: u32 = 0,
    ext_names: ?[*]const [*:0]const u8 = null,
};

/// VkPhysicalDeviceProperties, head fields only. The tail (limits +
/// sparseProperties) is ~530 bytes we don't need, so it stays opaque padding
/// rather than a transcribed struct we'd have to keep correct.
const PhysicalDeviceProperties = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: u32,
    device_name: [256]u8,
    pipeline_cache_uuid: [16]u8,
    tail: [1024]u8,
};

const GetInstanceProcAddr = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
const Negotiate = *const fn (*u32) callconv(.c) i32;
const EnumInstExt = *const fn (?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) i32;
const EnumInstLayers = *const fn (*u32, ?[*]LayerProperties) callconv(.c) i32;
const CreateInstance = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *?*anyopaque) callconv(.c) i32;
const EnumPhysDev = *const fn (?*anyopaque, *u32, ?[*]?*anyopaque) callconv(.c) i32;
const GetPhysProps = *const fn (?*anyopaque, *PhysicalDeviceProperties) callconv(.c) void;
const EnumDevExt = *const fn (?*anyopaque, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) i32;

var buf: [2 * 1024 * 1024]u8 = undefined;

fn ver(v: u32) struct { u32, u32, u32 } {
    return .{ (v >> 22) & 0x7F, (v >> 12) & 0x3FF, v & 0xFFF };
}

fn typeName(t: u32) []const u8 {
    return switch (t) {
        0 => "other",
        1 => "integrated-gpu",
        2 => "discrete-gpu",
        3 => "virtual-gpu",
        4 => "cpu",
        else => "?",
    };
}

/// Sorted for stable diffing between firmware versions.
fn lessThan(_: void, a: ExtensionProperties, b: ExtensionProperties) bool {
    return std.mem.order(u8, std.mem.sliceTo(&a.name, 0), std.mem.sliceTo(&b.name, 0)) == .lt;
}

pub fn main() !void {
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();

    const lib = c.dlopen("libmali.so", .{ .NOW = true }) orelse {
        std.debug.print("dlopen(libmali.so) failed\n", .{});
        return error.NoIcd;
    };

    const negotiate: Negotiate = @ptrCast(@alignCast(c.dlsym(lib, "vk_icdNegotiateLoaderICDInterfaceVersion") orelse return error.NoNegotiate));
    const gipa: GetInstanceProcAddr = @ptrCast(@alignCast(c.dlsym(lib, "vk_icdGetInstanceProcAddr") orelse return error.NoGipa));

    var icd_version: u32 = 5;
    const nres = negotiate(&icd_version);
    std.debug.print("ICD interface version: {d} (negotiate rc={d})\n", .{ icd_version, nres });

    const enumInstExt: EnumInstExt = @ptrCast(@alignCast(gipa(null, "vkEnumerateInstanceExtensionProperties") orelse return error.NoEnumInstExt));
    const enumInstLayers: ?EnumInstLayers = @ptrCast(@alignCast(gipa(null, "vkEnumerateInstanceLayerProperties")));
    const createInstance: CreateInstance = @ptrCast(@alignCast(gipa(null, "vkCreateInstance") orelse return error.NoCreateInstance));

    // ---- instance extensions ----
    var n: u32 = 0;
    _ = enumInstExt(null, &n, null);
    const inst_ext = try alloc.alloc(ExtensionProperties, n);
    _ = enumInstExt(null, &n, inst_ext.ptr);
    std.mem.sort(ExtensionProperties, inst_ext[0..n], {}, lessThan);
    std.debug.print("\n=== instance extensions ({d}) ===\n", .{n});
    for (inst_ext[0..n]) |e| std.debug.print("  {s} (rev {d})\n", .{ std.mem.sliceTo(&e.name, 0), e.spec_version });

    // ---- instance layers ----
    if (enumInstLayers) |f| {
        var ln: u32 = 0;
        _ = f(&ln, null);
        const layers = try alloc.alloc(LayerProperties, ln);
        _ = f(&ln, layers.ptr);
        std.debug.print("\n=== instance layers ({d}) ===\n", .{ln});
        for (layers[0..ln]) |l| std.debug.print("  {s} -- {s}\n", .{ std.mem.sliceTo(&l.name, 0), std.mem.sliceTo(&l.description, 0) });
    }

    // ---- instance ----
    const app = ApplicationInfo{ .app_name = "vkinfo", .api_version = API_1_3 };
    const ci = InstanceCreateInfo{ .app_info = &app };
    var instance: ?*anyopaque = null;
    const rc = createInstance(&ci, null, &instance);
    if (rc != VK_SUCCESS) {
        std.debug.print("\nvkCreateInstance failed: {d}\n", .{rc});
        return error.CreateInstanceFailed;
    }

    const enumPhys: EnumPhysDev = @ptrCast(@alignCast(gipa(instance, "vkEnumeratePhysicalDevices") orelse return error.NoEnumPhys));
    const getProps: GetPhysProps = @ptrCast(@alignCast(gipa(instance, "vkGetPhysicalDeviceProperties") orelse return error.NoGetProps));
    const enumDevExt: EnumDevExt = @ptrCast(@alignCast(gipa(instance, "vkEnumerateDeviceExtensionProperties") orelse return error.NoEnumDevExt));

    var dn: u32 = 0;
    _ = enumPhys(instance, &dn, null);
    const devs = try alloc.alloc(?*anyopaque, dn);
    _ = enumPhys(instance, &dn, devs.ptr);
    std.debug.print("\n=== physical devices ({d}) ===\n", .{dn});

    for (devs[0..dn]) |dev| {
        var props: PhysicalDeviceProperties = undefined;
        getProps(dev, &props);
        const a = ver(props.api_version);
        const d = ver(props.driver_version);
        std.debug.print(
            \\
            \\device: {s}
            \\  type={s}  vendorID=0x{x:0>4} deviceID=0x{x:0>4}
            \\  apiVersion={d}.{d}.{d}  driverVersion={d}.{d}.{d} (raw 0x{x})
            \\
        , .{
            std.mem.sliceTo(&props.device_name, 0), typeName(props.device_type),
            props.vendor_id,                        props.device_id,
            a[0],                                   a[1],
            a[2],                                   d[0],
            d[1],                                   d[2],
            props.driver_version,
        });

        var en: u32 = 0;
        _ = enumDevExt(dev, null, &en, null);
        const exts = try alloc.alloc(ExtensionProperties, en);
        _ = enumDevExt(dev, null, &en, exts.ptr);
        std.mem.sort(ExtensionProperties, exts[0..en], {}, lessThan);
        std.debug.print("  === device extensions ({d}) ===\n", .{en});
        for (exts[0..en]) |e| std.debug.print("    {s} (rev {d})\n", .{ std.mem.sliceTo(&e.name, 0), e.spec_version });
    }
}
