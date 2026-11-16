//! The Vulkan library and the instance. The loader (libvulkan, the platform's) is opened at run
//! time and every function is fetched through `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`
//! into tables of the functions this back end calls, nothing more: no link-time dependency on
//! the loader, no wrapper layer, no allocation. Headers are Khronos Vulkan-Headers'
//! vulkan_core.h, translated by build.zig with VK_NO_PROTOTYPES (`vk_c`).
//!
//!     var lib = try loader.Library.open();
//!     defer lib.close();
//!     var instance = try loader.Instance.init(&lib, .{ .extensions = &.{"VK_KHR_surface"} });
//!     defer instance.deinit();

const std = @import("std");
const builtin = @import("builtin");
pub const c = @import("vk_c");

pub const Error = error{ NoLoader, MissingFunction, VulkanTooOld, MissingExtension, MissingLayer, InitializationFailed, OutOfMemory, DeviceLost, SurfaceLost, OutOfDate, ZeroExtent, Unknown };

/// Maps a failing VkResult to an error. Success codes (SUBOPTIMAL included) are not errors.
pub fn check(r: c.VkResult) Error!void {
    if (r >= 0) return;
    return switch (r) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY, c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfMemory,
        c.VK_ERROR_INITIALIZATION_FAILED, c.VK_ERROR_INCOMPATIBLE_DRIVER => error.InitializationFailed,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.MissingExtension,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.MissingLayer,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLost,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDate,
        else => error.Unknown,
    };
}

/// Fills every field of `T` (each a Vulkan PFN, named exactly as the Vulkan function) from
/// `get(handle, name)`. A function the implementation does not return is an error: the tables
/// list only what this back end calls. `get` is vkGetInstanceProcAddr or vkGetDeviceProcAddr,
/// `handle` the instance or device it takes.
pub fn load(comptime T: type, get: anytype, handle: anytype) Error!T {
    var t: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        const f = get.?(handle, name.ptr) orelse return error.MissingFunction;
        @field(t, name) = @as(FT, @ptrCast(f));
    }
    return t;
}

/// Loader-level functions: callable before any instance exists.
pub const GlobalFns = struct {
    vkEnumerateInstanceVersion: c.PFN_vkEnumerateInstanceVersion,
    vkEnumerateInstanceExtensionProperties: c.PFN_vkEnumerateInstanceExtensionProperties,
    vkEnumerateInstanceLayerProperties: c.PFN_vkEnumerateInstanceLayerProperties,
    vkCreateInstance: c.PFN_vkCreateInstance,
};

/// The platform loader, opened by name. The process keeps one copy of it however many times
/// it is opened (the dynamic linker counts references).
pub const Library = struct {
    handle: *anyopaque,
    getInstanceProcAddr: c.PFN_vkGetInstanceProcAddr,
    fns: GlobalFns,

    const names: []const [:0]const u8 = switch (builtin.os.tag) {
        .windows => &.{"vulkan-1.dll"},
        .macos, .ios => &.{ "libvulkan.1.dylib", "libMoltenVK.dylib" },
        else => &.{ "libvulkan.so.1", "libvulkan.so" },
    };

    pub fn open() Error!Library {
        const handle = for (names) |name| {
            if (std.c.dlopen(name, .{ .NOW = true })) |h| break h;
        } else return error.NoLoader;
        errdefer _ = std.c.dlclose(handle);
        const sym = std.c.dlsym(handle, "vkGetInstanceProcAddr") orelse return error.NoLoader;
        const get: c.PFN_vkGetInstanceProcAddr = @ptrCast(sym);
        return .{ .handle = handle, .getInstanceProcAddr = get, .fns = try load(GlobalFns, get, @as(c.VkInstance, null)) };
    }

    pub fn close(lib: *Library) void {
        _ = std.c.dlclose(lib.handle);
    }

    /// The highest Vulkan version the loader supports, as VK_MAKE_API_VERSION packs it.
    pub fn version(lib: *const Library) u32 {
        var v: u32 = 0;
        _ = lib.fns.vkEnumerateInstanceVersion.?(&v);
        return v;
    }

    /// Whether the loader or an implicit layer provides instance extension `name`.
    pub fn hasExtension(lib: *const Library, name: []const u8) bool {
        var props: [256]c.VkExtensionProperties = undefined;
        var n: u32 = props.len;
        _ = lib.fns.vkEnumerateInstanceExtensionProperties.?(null, &n, &props);
        return hasName(props[0..n], name);
    }

    pub fn hasLayer(lib: *const Library, name: []const u8) bool {
        var props: [64]c.VkLayerProperties = undefined;
        var n: u32 = props.len;
        _ = lib.fns.vkEnumerateInstanceLayerProperties.?(&n, &props);
        for (props[0..n]) |p| if (std.mem.eql(u8, std.mem.sliceTo(&p.layerName, 0), name)) return true;
        return false;
    }
};

pub fn hasName(props: []const c.VkExtensionProperties, name: []const u8) bool {
    for (props) |p| if (std.mem.eql(u8, std.mem.sliceTo(&p.extensionName, 0), name)) return true;
    return false;
}

/// Vulkan 1.3: dynamic rendering and synchronization2 are core, so no render pass objects and
/// no extension juggling.
pub const api_version = c.VK_API_VERSION_1_3;

/// Instance-level functions this back end calls.
pub const InstanceFns = struct {
    vkDestroyInstance: c.PFN_vkDestroyInstance,
    vkEnumeratePhysicalDevices: c.PFN_vkEnumeratePhysicalDevices,
    vkGetPhysicalDeviceProperties: c.PFN_vkGetPhysicalDeviceProperties,
    vkGetPhysicalDeviceFeatures2: c.PFN_vkGetPhysicalDeviceFeatures2,
    vkGetPhysicalDeviceQueueFamilyProperties: c.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    vkGetPhysicalDeviceMemoryProperties: c.PFN_vkGetPhysicalDeviceMemoryProperties,
    vkEnumerateDeviceExtensionProperties: c.PFN_vkEnumerateDeviceExtensionProperties,
    vkCreateDevice: c.PFN_vkCreateDevice,
    vkGetDeviceProcAddr: c.PFN_vkGetDeviceProcAddr,
};

/// Surface functions, loaded when VK_KHR_surface was enabled.
pub const SurfaceFns = struct {
    vkDestroySurfaceKHR: c.PFN_vkDestroySurfaceKHR,
    vkGetPhysicalDeviceSurfaceSupportKHR: c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
    vkGetPhysicalDeviceSurfaceFormatsKHR: c.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR,
    vkGetPhysicalDeviceSurfacePresentModesKHR: c.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR,
};

pub const InstanceDesc = struct {
    app_name: [:0]const u8 = "lcgr",
    /// Instance extensions the host needs: VK_KHR_surface plus its platform's surface extension
    /// (the shell knows which), or none for offscreen rendering.
    extensions: []const [*:0]const u8 = &.{},
    /// Enables VK_LAYER_KHRONOS_validation when it is installed; skipped silently when not.
    validation: bool = false,
};

pub const Instance = struct {
    handle: c.VkInstance,
    getInstanceProcAddr: c.PFN_vkGetInstanceProcAddr,
    fns: InstanceFns,
    /// Null unless VK_KHR_surface was among the extensions.
    surface: ?SurfaceFns,

    pub fn init(lib: *const Library, desc: InstanceDesc) Error!Instance {
        if (lib.version() < api_version) return error.VulkanTooOld;
        const validation = "VK_LAYER_KHRONOS_validation";
        const layers = [_][*:0]const u8{validation};
        const use_validation = desc.validation and lib.hasLayer(validation);
        const app: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = desc.app_name.ptr,
            .pEngineName = "lcgr",
            .apiVersion = api_version,
        };
        var handle: c.VkInstance = null;
        try check(lib.fns.vkCreateInstance.?(&.{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app,
            .enabledLayerCount = @intFromBool(use_validation),
            .ppEnabledLayerNames = &layers,
            .enabledExtensionCount = @intCast(desc.extensions.len),
            .ppEnabledExtensionNames = desc.extensions.ptr,
        }, null, &handle));
        const get = lib.getInstanceProcAddr;
        const fns = load(InstanceFns, get, handle) catch |e| {
            if (@as(c.PFN_vkDestroyInstance, @ptrCast(get.?(handle, "vkDestroyInstance")))) |destroy| destroy(handle, null);
            return e;
        };
        var surface: ?SurfaceFns = null;
        for (desc.extensions) |e| {
            if (std.mem.eql(u8, std.mem.span(e), "VK_KHR_surface")) surface = load(SurfaceFns, get, handle) catch null;
        }
        return .{ .handle = handle, .getInstanceProcAddr = get, .fns = fns, .surface = surface };
    }

    pub fn deinit(instance: *Instance) void {
        instance.fns.vkDestroyInstance.?(instance.handle, null);
    }

    /// An instance function outside the tables (a platform's vkCreate*SurfaceKHR, a debug
    /// extension), or null when the instance does not have it.
    pub fn proc(instance: *const Instance, comptime T: type, name: [*:0]const u8) T {
        return @ptrCast(instance.getInstanceProcAddr.?(instance.handle, name));
    }
};

const testing = std.testing;

test "loader: opens the platform's libvulkan and creates a Vulkan 1.3 instance" {
    var lib = try Library.open();
    defer lib.close();
    try testing.expect(lib.version() >= api_version);
    try testing.expect(lib.hasExtension("VK_KHR_surface"));
    var instance = try Instance.init(&lib, .{ .extensions = &.{"VK_KHR_surface"} });
    defer instance.deinit();
    try testing.expect(instance.handle != null);
    try testing.expect(instance.surface != null);
    try testing.expect(instance.proc(c.PFN_vkCreateHeadlessSurfaceEXT, "vkCreateHeadlessSurfaceEXT") == null); // not enabled
}

test "loader: an instance without extensions has no surface functions" {
    var lib = try Library.open();
    defer lib.close();
    var instance = try Instance.init(&lib, .{});
    defer instance.deinit();
    try testing.expect(instance.surface == null);
}

test "loader: an unknown extension is reported, not crashed on" {
    var lib = try Library.open();
    defer lib.close();
    try testing.expectError(error.MissingExtension, Instance.init(&lib, .{ .extensions = &.{"VK_LCGR_not_an_extension"} }));
}

test "check: success codes pass, failures map to errors" {
    try check(c.VK_SUCCESS);
    try check(c.VK_SUBOPTIMAL_KHR);
    try testing.expectError(error.DeviceLost, check(c.VK_ERROR_DEVICE_LOST));
    try testing.expectError(error.OutOfDate, check(c.VK_ERROR_OUT_OF_DATE_KHR));
}
