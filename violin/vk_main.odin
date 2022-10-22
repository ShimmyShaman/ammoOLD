package violin

import "core:fmt"
import "core:os"
import "core:mem"
import "core:c"
import "core:c/libc"
import "core:strings"
import "core:sync"
import "core:time"

import "vendor:sdl2"
import vk "vendor:vulkan"

import vma "../deps/odin-vma"

foreign import alibc "system:c"
@(default_calling_convention="c")
foreign alibc {
    system :: proc(cmd: cstring) -> c.int ---
}

// mat4 :: distinct matrix[4,4]f32

MAX_FRAMES_IN_FLIGHT :: 2
MAX_DESCRIPTOR_SETS :: 4096

Error :: enum {
  Success,
  NotYetImplemented,
  NotYetDetailed,
  VulkanLayerNotAvailable,
  NoQueueAvailableOnDevice,
  AllocationFailed,
  ResourceNotFound,
  InvalidState,
}

Context :: struct {
  violin_package_relative_path: string,
  window:   ^sdl2.Window,

  vma_allocator: vma.Allocator,
  resource_manager: ResourceManager,

  extensions_count: u32,
  extensions_names: [^]cstring,

  instance: vk.Instance,
  device:   vk.Device,
  physical_device: vk.PhysicalDevice,
  swap_chain: Swapchain,
  queue_indices:   [QueueFamily]int,
  queues:   [QueueFamily]vk.Queue,
  surface:  vk.SurfaceKHR,
  command_pool: vk.CommandPool,
  st_command_buffer: vk.CommandBuffer,
  
  framebuffer_resized: bool,

  in_flight_mutex: sync.Mutex,
  in_flight_index: u32,
  _render_contexts: [MAX_FRAMES_IN_FLIGHT]RenderContext,
}

Swapchain :: struct {
  handle: vk.SwapchainKHR,
  format: vk.SurfaceFormatKHR,
  extent: vk.Extent2D,
  present_mode: vk.PresentModeKHR,
  image_count: u32,
  support: SwapChainDetails,
  images: []vk.Image,
  image_views: []vk.ImageView,
  command_buffers: []vk.CommandBuffer,
}

RenderContext :: struct {
  ctx: ^Context,

  mutex: sync.Mutex,
  status: FrameRenderStateKind,
  swap_chain_index: u32,

  image_available: vk.Semaphore,
  render_finished: vk.Semaphore,
  in_flight: vk.Fence,

  active_render_pass: RenderPassResourceHandle,
  followup_render_pass: RenderPassResourceHandle,
  // present_framebuffer: vk.Framebuffer,

  image: vk.Image,
  image_view: vk.ImageView,
  command_buffer: vk.CommandBuffer,

  descriptor_pool: vk.DescriptorPool,
  descriptor_sets: [MAX_DESCRIPTOR_SETS]vk.DescriptorSet,
  descriptor_sets_index: u32,
}

FrameRenderStateKind :: enum {
  Idle,
  Initializing,
  Initialized,
  RenderPass,
  StampRenderPass,
  EndedRenderPass,
}

Pipeline :: struct {
  handle: vk.Pipeline,
  layout: vk.PipelineLayout,
}

QueueFamily :: enum {
  Graphics,
  Present,
}

SwapChainDetails :: struct {
  capabilities: vk.SurfaceCapabilitiesKHR,
  formats: []vk.SurfaceFormatKHR,
  present_modes: []vk.PresentModeKHR,
}

ShaderKind :: enum {
  Vertex,
  Fragment,
}

RenderPassConfigFlags :: distinct bit_set[RenderPassConfigFlag; vk.Flags]
RenderPassConfigFlag :: enum vk.Flags {
  HasPreviousColorPass = 0,
	IsPresent            = 1,
  HasDepthBuffer       = 2,
}

DEVICE_EXTENSIONS := [?]cstring{
  "VK_KHR_swapchain",
};
VALIDATION_LAYERS := [?]cstring {
  "VK_LAYER_KHRONOS_validation",
}

init :: proc(violin_package_relative_path: string) -> (ctx: ^Context, err: Error) {
  using sdl2

  err = .Success

  ctx = new(Context)
  ctx.violin_package_relative_path = strings.clone(violin_package_relative_path)

  // Init
  result := auto_cast Init(INIT_VIDEO)
  if result != 0 {
    fmt.println("Error initializing sdl2: ", result)
    err = .NotYetDetailed
    return
  }
  
  // Vulkan Library
  result = auto_cast Vulkan_LoadLibrary(nil)
  if result != 0 {
    fmt.println("Error loading Vulkan Library: ", result)
    err = .NotYetDetailed
    return
  }

  // Window
  ctx.window = CreateWindow("OdWin", WINDOWPOS_UNDEFINED, WINDOWPOS_UNDEFINED, 960, 600, WINDOW_SHOWN | WINDOW_VULKAN)

  init_vulkan(ctx) or_return
  return
}

init_vulkan :: proc(using ctx: ^Context) -> Error {
  _init_resource_manager(&ctx.resource_manager) or_return

  context.user_ptr = &instance;
  get_proc_address :: proc(p: rawptr, name: cstring) 
  {
    vkGetInstanceProcAddr := cast(vk.ProcGetInstanceProcAddr) sdl2.Vulkan_GetVkGetInstanceProcAddr()
    (cast(^rawptr)p)^ = auto_cast vkGetInstanceProcAddr((^vk.Instance)(context.user_ptr)^, name)
  // fmt.println("called for:", name, " == ", (cast(^rawptr)p)^)
  }
  
  vk.load_proc_addresses(get_proc_address);
  _create_instance(ctx);
  vk.load_proc_addresses(get_proc_address);
  
  _create_surface_and_set_device(ctx) or_return
  
  fmt.println("Queue Indices:");
  for q, f in queue_indices do fmt.printf("  %v: %d\n", f, q);
  
  _create_logical_device(ctx) or_return
  
  for q, f in &queues do vk.GetDeviceQueue(device, u32(queue_indices[f]), 0, &q)

  for i in 0..<MAX_FRAMES_IN_FLIGHT {
    _render_contexts[i].ctx = ctx
    _render_contexts[i].status = .Idle
  }
  
  _init_vma(ctx) or_return
  
  create_swap_chain(ctx)
  create_image_views(ctx)

  create_command_pool(ctx) or_return
  
  create_command_buffers(ctx) or_return
  create_sync_objects(ctx) or_return

  _init_descriptor_pool(ctx) or_return

  return .Success
}

quit :: proc(using ctx: ^Context) {
  vk.DeviceWaitIdle(device);
  
  deinit_vulkan(ctx);

  sdl2.DestroyWindow(window);
  sdl2.Vulkan_UnloadLibrary()
  sdl2.Quit()

  delete_string(ctx.violin_package_relative_path)
  free(ctx)
}

destroy_render_program :: proc(using ctx: ^Context, render_program: ^RenderProgram) {
  vk.DeviceWaitIdle(device); // TODO -- will 'probably' need better synchronization

  if render_program.pipeline.handle != 0 do vk.DestroyPipeline(device, render_program.pipeline.handle, nil)
  if render_program.pipeline.layout != 0 do vk.DestroyPipelineLayout(device, render_program.pipeline.layout, nil)
  
  if render_program.descriptor_layout != 0 do vk.DestroyDescriptorSetLayout(device, render_program.descriptor_layout, nil)
}

deinit_vulkan :: proc(using ctx: ^Context) {
  cleanup_swap_chain(ctx);
  
  vk.FreeCommandBuffers(device, command_pool, u32(len(swap_chain.command_buffers)), &swap_chain.command_buffers[0])
  delete(swap_chain.command_buffers)

  for i in 0..<MAX_FRAMES_IN_FLIGHT
  {
    vk.DestroySemaphore(device, _render_contexts[i].image_available, nil)
    vk.DestroySemaphore(device, _render_contexts[i].render_finished, nil)
    vk.DestroyFence(device, _render_contexts[i].in_flight, nil)

    vk.DestroyDescriptorPool(device, _render_contexts[i].descriptor_pool, nil)
  }
  vk.DestroyCommandPool(device, command_pool, nil);
  
  vma.DestroyAllocator(vma_allocator)

  vk.DestroyDevice(device, nil);
  vk.DestroySurfaceKHR(instance, surface, nil);
  destroy_instance(ctx)
}

/*
  Compiles the shader from the src path relative to SHADER_DIRECTORY
*/
compile_shader :: proc(shader_src_path: string, kind: ShaderKind) -> (data: []u8) {
  data = nil

  // Check
  CACHE_DIRECTORY :: "bin/_sgen/" // Shader -- TODO label better
  glslc_LOCATION :: "/media/bug/rome/prog/shaderc/bin/glslc"
  if !os.exists(glslc_LOCATION) {
    fmt.println("ERROR: need to set glslc_LOCATION to where it is (or make it accessable)")
    return
  }
  if !os.exists(CACHE_DIRECTORY) {
    os.make_directory(CACHE_DIRECTORY)
  }
  
  shader_file_name: string
  i := strings.last_index_any(shader_src_path, "/\\")
  if i > 0 && i + 1 < len(shader_src_path) {
    shader_file_name = strings.clone(shader_src_path[i + 1:])
  } else {
    shader_file_name = strings.clone(shader_src_path)
  }
  defer delete_string(shader_file_name)
  // fmt.println("shader_file_name:", shader_file_name)

  ext_cache_path, maerr := strings.concatenate_safe([]string { CACHE_DIRECTORY, shader_file_name, ".spv" })
  if maerr != mem.Allocator_Error.None {
    fmt.println("compile_shader > cache strings.concatenate_safe Memory Allocator Error:", maerr)
    return
  }
  defer delete(ext_cache_path)

  errno: os.Errno
  h_src, h_cache: os.Handle

  // Open the source file
  h_src, errno = os.open(shader_src_path)
  if errno != os.ERROR_NONE {
    fmt.printf("Error compile_shader(): couldn't open shader path='%s' set relative_src_path accordingly\n", shader_src_path)
    fmt.println("--CurrentWorkingDirectory:", os.get_current_directory())
    libc.perror("File I/O Error:")
    return
  }
  defer os.close(h_src)

  // Attempt to open the cache file instead of recompiling
  cache_file_info: os.File_Info
  // if os.exists(ext_cache_path) {
  //   cache_file_info, errno = os.stat(ext_cache_path)
  //   if errno != os.ERROR_Ok {
  //     fmt.println("Couldn't obtain file info for cache shader file:", ext_cache_path)
  //     err = cast(int) errno
  //     return
  //   }

  //   src_file_info: os.File_Info
  //   src_file_info, errno = os.stat(ext_src_path)
  //   if errno != os.ERROR_Ok {
  //     fmt.println("Couldn't obtain file info for src shader file:", ext_src_path)
  //     err = cast(int) errno
  //     return
  //   }

  //   if cache_file_info.modification_time._nsec > src_file_info.modification_time._nsec {
  //     // Cache compiled file is more recent than source shader file
  //     // -- Use that
  //     h_cache, errno = os.open(ext_cache_path)
  //     if errno != os.ERROR_Ok {
  //       // Ignore and just recompile anyway
  //       h_cache = os.Handle(0)
  //     }
  //   }
  // }

  if h_cache == os.Handle(0) {
    // Compile the file via a commandline call
    cmd: string
    cmd, maerr = strings.concatenate_safe([]string { glslc_LOCATION, " -o ", ext_cache_path, " ", shader_src_path }) // -mfmt=bin
    if maerr != .None {
      return
    }
    defer delete(cmd)
    
    cmd_cstr := strings.clone_to_cstring(cmd)
    defer delete(cmd_cstr)
  
    system(cmd_cstr)

    // Open it
    h_cache, errno = os.open(ext_cache_path)
    if errno != os.ERROR_NONE {
      fmt.println("Couldn't obtain compiled shader file:", ext_cache_path)
      return
    }
    cache_file_info, errno = os.stat(ext_cache_path)
  }
  defer os.close(h_cache)

  read_success: bool
  data, read_success = os.read_entire_file_from_handle(h_cache)
  if !read_success {
    fmt.println("Could not read full file from cache file handle:", ext_cache_path, " >", h_cache)
    return
  }


  return
}

init_vulkan_extensions :: proc(ctx: ^Context) {

  extra_ext_count : u32 : 0
  sdl2.Vulkan_GetInstanceExtensions(ctx.window, &ctx.extensions_count, nil)
  if ctx.extensions_count + extra_ext_count > 0 {
    ctx.extensions_names = cast([^]cstring)mem.alloc(cast(int)((ctx.extensions_count + extra_ext_count) * size_of(cstring)))
    sdl2.Vulkan_GetInstanceExtensions(ctx.window, &ctx.extensions_count, ctx.extensions_names);
  }

  // ctx.extensions_count += extra_ext_count
  // ctx.extensions_names[ctx.extensions_count] = vk.EXT_DEBUG_UTILS_EXTENSION_NAME

  // for i in 0..<ctx.extensions_count do fmt.println("--extension: ", ctx.extensions_names[i])
}

check_vulkan_layer_support :: proc(create_info: ^vk.InstanceCreateInfo) -> Error {
    when ODIN_DEBUG
    {
      layer_count: u32;
      vk.EnumerateInstanceLayerProperties(&layer_count, nil);
      layers := make([]vk.LayerProperties, layer_count);
      vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers));

      builder := strings.builder_make(context.temp_allocator)
      for layer in layers {
        for b in layer.layerName {
          if b == 0 do break
          strings.write_byte(&builder, b)
        }
        
        // fmt.println("--", strings.to_string(builder))
        strings.builder_reset(&builder)
      }
      
      outer: for name in VALIDATION_LAYERS
      {
        for layer in &layers
        {
          if name == cstring(&layer.layerName[0]) do continue outer;
        }
        fmt.eprintf("ERROR: validation layer %q not available\n", name);
        return .VulkanLayerNotAvailable
      }
      
      when len(VALIDATION_LAYERS) > 0 {
        create_info.enabledLayerCount = cast(u32)len(VALIDATION_LAYERS)
        create_info.ppEnabledLayerNames = &VALIDATION_LAYERS[0]
      } else {
        create_info.enabledLayerCount = 0
        create_info.ppEnabledLayerNames = nil
      }
      fmt.println("Validation Layers Loaded");
    }
    else
    {
      create_info.enabledLayerCount = 0;
    }
  return .Success
}

_create_instance :: proc(ctx: ^Context) -> Error {
  app_info := vk.ApplicationInfo {
    sType = .APPLICATION_INFO,
    pApplicationName = "Violin Experiment",
    applicationVersion = vk.MAKE_VERSION(0, 1, 1),
    pEngineName = "Violin Renderer",
    engineVersion = vk.MAKE_VERSION(0, 1, 1),
    apiVersion = vk.API_VERSION_1_0,
  }

  init_vulkan_extensions(ctx)
  create_info := vk.InstanceCreateInfo {
    sType = .INSTANCE_CREATE_INFO,
    pApplicationInfo = &app_info,
    enabledExtensionCount = ctx.extensions_count,
    ppEnabledExtensionNames = ctx.extensions_names,
  }
  check_vulkan_layer_support(&create_info)


  // Initialize GetInstanceProcAddr
  context.user_ptr = &ctx.instance;
  get_proc_address :: proc(p: rawptr, name: cstring) 
  {
    vkGetInstanceProcAddr := cast(vk.ProcGetInstanceProcAddr) sdl2.Vulkan_GetVkGetInstanceProcAddr()
    (cast(^rawptr)p)^ = auto_cast vkGetInstanceProcAddr((^vk.Instance)(context.user_ptr)^, name)
  // fmt.println("called for:", name, " == ", (cast(^rawptr)p)^)
  }
  vk.load_proc_addresses(get_proc_address)
  
  // Create Instance
  vkres := vk.CreateInstance(&create_info, nil, &ctx.instance)
  if vkres != .SUCCESS {
    fmt.eprintln("Error creating Vulkan Instance:", vkres)
    return .NotYetDetailed
  }
  fmt.println("created vk Instance")

  // Reiterate procedure load with the instance set
  vk.load_proc_addresses(get_proc_address)

  return .Success
}

destroy_instance :: proc(ctx: ^Context) {
  if ctx.instance != nil {
    vk.DestroyInstance(ctx.instance, nil)
  }
}

_set_physical_device_queue_families :: proc(surface: vk.SurfaceKHR, physical_device: vk.PhysicalDevice,
  suppress_missing_queue_messages := false) -> (graphics_queue_index: int, present_queue_index: int, err: Error) {
  graphics_queue_index = -1
  present_queue_index = -1

  queue_count: u32;
  vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, nil);
  available_queues, alerr := make([]vk.QueueFamilyProperties, queue_count)
  if alerr != .None {
    fmt.eprintln("Error allocating queue family properties")
    err = .NotYetDetailed
    return
  }
  defer delete(available_queues)
  vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, raw_data(available_queues))

  // Iterate over each queue to discover if it supports presenting on the created surface
  p_supports_present := cast([^]b32)mem.alloc(cast(int)(queue_count * size_of(b32)))
  defer mem.free(p_supports_present)

  for i in 0..<queue_count {
    vkres := vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, i, surface, &p_supports_present[i])
    if vkres != .SUCCESS {
      fmt.println("Error GetPhysicalDeviceSurfaceSupportKHR:", vkres)
      err = .NotYetDetailed
      return
    }
  }

  // Search for a graphics queue and a present queue in the array of queue families
  // First attempt to find a queue family that supports both
  for i in 0..<queue_count {
    if .GRAPHICS in available_queues[i].queueFlags {
      if p_supports_present[i] {
        // Found Family that supports both
        graphics_queue_index = auto_cast i
        present_queue_index = auto_cast i

        // Success
        return
      }

      if graphics_queue_index < 0 {
        graphics_queue_index = auto_cast i
      }
    }
  }

  if graphics_queue_index < 0 {
    if !suppress_missing_queue_messages do fmt.eprintln("Could not find a graphics queue on the primary device")
    err = .NoQueueAvailableOnDevice
    return
  }

  // If there's no family that supports both, then find a separate present queue
  for i in 0..<queue_count {
    if p_supports_present[i] {
      present_queue_index = auto_cast i

      // Success
      return
    }
  }

  if !suppress_missing_queue_messages do fmt.eprintln("Could not find a present queue on the primary device")
  err = .NoQueueAvailableOnDevice
  return
}

check_device_extension_support :: proc(physical_device: vk.PhysicalDevice) -> bool {
  ext_count: u32;
  vk.EnumerateDeviceExtensionProperties(physical_device, nil, &ext_count, nil);
  
  available_extensions := make([]vk.ExtensionProperties, ext_count);
  vk.EnumerateDeviceExtensionProperties(physical_device, nil, &ext_count, raw_data(available_extensions));
  
  for ext in DEVICE_EXTENSIONS
  {
    found: b32;
    for available in &available_extensions
    {
      if cstring(&available.extensionName[0]) == ext
      {
        found = true;
        break;
      }
    }
    if !found do return false;
  }
  return true;
}
  
_determine_device_suitability :: proc(using ctx: ^Context, dev: vk.PhysicalDevice) -> (score :int, err: Error) {
  score = 0

  g, p, res := _set_physical_device_queue_families(surface, dev, true)
  if res == .NoQueueAvailableOnDevice {
    return
  } else if res != .Success {
    err = res
    return
  }
  if g == p do score += 99

  props: vk.PhysicalDeviceProperties;
  features: vk.PhysicalDeviceFeatures;
  vk.GetPhysicalDeviceProperties(dev, &props);
  vk.GetPhysicalDeviceFeatures(dev, &features);
  
  if props.deviceType == .DISCRETE_GPU do score += 1000;
  score += cast(int)props.limits.maxImageDimension2D;
  
  if !features.geometryShader do return
  if !check_device_extension_support(dev) do return
  
  _query_swap_chain_details(ctx, dev);
  if len(swap_chain.support.formats) == 0 || len(swap_chain.support.present_modes) == 0 do return
  
  return
}

_create_surface_and_set_device :: proc(using ctx: ^Context) -> Error {
  // Create Surface
  if !sdl2.Vulkan_CreateSurface(window, instance, &surface) {
    fmt.eprintln("Error creating SDL2 Vulkan Surface")
    return .NotYetDetailed
  }
  
  // Find a suitable Physical Device for the surface
  device_count: u32;
  vk.EnumeratePhysicalDevices(instance, &device_count, nil);
  if device_count == 0 {
    fmt.eprintf("ERROR: Failed to find GPUs with Vulkan support\n");
    return .NotYetDetailed
  }
  devices := make([]vk.PhysicalDevice, device_count);
  defer delete(devices)
  vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices));

  hiscore := 0;
  for dev in devices {
    score := _determine_device_suitability(ctx, dev) or_return
    if score > hiscore {
      physical_device = dev;
      hiscore = score;
    }
  }
  if (hiscore == 0) {
    fmt.eprintf("ERROR: Failed to find a suitable GPU\n");
    return .NotYetDetailed
  }

  return .Success
}

_create_logical_device :: proc(using ctx: ^Context) -> Error {
  unique_indices: map[int]b8;
  defer delete(unique_indices);
  for i in queue_indices do unique_indices[i] = true;
  
  queue_priority := f32(1.0);
  
  queue_create_infos: [dynamic]vk.DeviceQueueCreateInfo;
  defer delete(queue_create_infos);
  for k, _ in unique_indices
  {
    queue_create_info: vk.DeviceQueueCreateInfo;
    queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO;
    queue_create_info.queueFamilyIndex = u32(queue_indices[.Graphics]);
    queue_create_info.queueCount = 1;
    queue_create_info.pQueuePriorities = &queue_priority;
    append(&queue_create_infos, queue_create_info);
  }
  
  device_features: vk.PhysicalDeviceFeatures;
  device_create_info: vk.DeviceCreateInfo;
  device_create_info.sType = .DEVICE_CREATE_INFO;
  device_create_info.enabledExtensionCount = u32(len(DEVICE_EXTENSIONS));
  device_create_info.ppEnabledExtensionNames = &DEVICE_EXTENSIONS[0];
  device_create_info.pQueueCreateInfos = raw_data(queue_create_infos);
  device_create_info.queueCreateInfoCount = u32(len(queue_create_infos));
  device_create_info.pEnabledFeatures = &device_features;
  device_create_info.enabledLayerCount = 0;
  
  vkres := vk.CreateDevice(physical_device, &device_create_info, nil, &device)
  if vkres != .SUCCESS {
    fmt.eprintln("ERROR: Failed to create logical device:", vkres);
    return .NotYetDetailed
  }

  return .Success
}

_init_vma :: proc(using ctx: ^Context) -> Error {
  vulkan_functions := vma.create_vulkan_functions();

  props: vk.PhysicalDeviceProperties
  vk.GetPhysicalDeviceProperties(physical_device, &props)
  // fmt.println("Api version:")
  // fmt.println("-- API_VERSION_1_0:", vk.API_VERSION_1_0)
  // fmt.println("-- API_VERSION_1_1:", vk.API_VERSION_1_1)
  // fmt.println("-- API_VERSION_1_2:", vk.API_VERSION_1_2)
  // fmt.println("-- API_VERSION_1_3:", vk.API_VERSION_1_3)
  // fmt.println(props)
  // TODO set vulkanApiVersion to the version supported by the device not 1_0 below

  vma_allocator_create_info := vma.AllocatorCreateInfo {
    vulkanApiVersion = vk.API_VERSION_1_0,
    instance = instance,
    physicalDevice = physical_device,
    device = device,
    // preferredLargeHeapBlockSize = 0,
    // pAllocationCallbacks = nil,
    // pDeviceMemoryCallbacks = nil,
    // pHeapSizeLimit = nil,
    pVulkanFunctions = &vulkan_functions,
    // pRecordSettings = nil,
  }

  vkres := vma.CreateAllocator(&vma_allocator_create_info, &vma_allocator)
  if vkres != .SUCCESS {
    fmt.eprintln("vma.CreateAllocator:", vkres)
    return .NotYetDetailed
  }

  return .Success
}

_query_swap_chain_details :: proc(using ctx: ^Context, dev: vk.PhysicalDevice) {
  vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(dev, surface, &swap_chain.support.capabilities);
  
  format_count: u32;
  vk.GetPhysicalDeviceSurfaceFormatsKHR(dev, surface, &format_count, nil);
  if format_count > 0 {
    swap_chain.support.formats = make([]vk.SurfaceFormatKHR, format_count);
    vk.GetPhysicalDeviceSurfaceFormatsKHR(dev, surface, &format_count, raw_data(swap_chain.support.formats));
  }
  
  present_mode_count: u32;
  vk.GetPhysicalDeviceSurfacePresentModesKHR(dev, surface, &present_mode_count, nil);
  if present_mode_count > 0
  {
    swap_chain.support.present_modes = make([]vk.PresentModeKHR, present_mode_count);
    vk.GetPhysicalDeviceSurfacePresentModesKHR(dev, surface, &present_mode_count, raw_data(swap_chain.support.present_modes));
  }
}

choose_surface_format :: proc(using ctx: ^Context) -> vk.SurfaceFormatKHR {
  for v in swap_chain.support.formats
  {
    if v.format == .B8G8R8A8_SRGB && v.colorSpace == .SRGB_NONLINEAR do return v;
  }
  
  return swap_chain.support.formats[0];
}

choose_present_mode :: proc(using ctx: ^Context) -> vk.PresentModeKHR {
  for v in swap_chain.support.present_modes
  {
    if v == .MAILBOX do return v;
  }
  
  for v in swap_chain.support.present_modes
  {
    // TODO -- this results in visual tearing but gives me fps clues
    if v == .IMMEDIATE do return v;
  }
  
  return .FIFO;
}

get_window_size :: proc(window: ^sdl2.Window) -> (width: i32, height: i32) {
  sdl2.GetWindowSize(window, &width, &height)
  return
}

choose_swap_extent :: proc(using ctx: ^Context) -> vk.Extent2D {
  if (swap_chain.support.capabilities.currentExtent.width != max(u32)) {
    return swap_chain.support.capabilities.currentExtent;
  }

  width, height := get_window_size(window)
  
  extent := vk.Extent2D{u32(width), u32(height)};
  
  extent.width = clamp(extent.width, swap_chain.support.capabilities.minImageExtent.width, swap_chain.support.capabilities.maxImageExtent.width);
  extent.height = clamp(extent.height, swap_chain.support.capabilities.minImageExtent.height, swap_chain.support.capabilities.maxImageExtent.height);
  
  return extent;
}

create_swap_chain :: proc(using ctx: ^Context) {
  using ctx.swap_chain.support;

  swap_chain.format       = choose_surface_format(ctx);
  swap_chain.present_mode = choose_present_mode(ctx);
  swap_chain.extent       = choose_swap_extent(ctx);
  swap_chain.image_count  = capabilities.minImageCount + 1;
  
  if capabilities.maxImageCount > 0 && swap_chain.image_count > capabilities.maxImageCount {
    swap_chain.image_count = capabilities.maxImageCount;
  }
  
  create_info: vk.SwapchainCreateInfoKHR;
  create_info.sType = .SWAPCHAIN_CREATE_INFO_KHR;
  create_info.surface = surface;
  create_info.minImageCount = swap_chain.image_count;
  create_info.imageFormat = swap_chain.format.format;
  create_info.imageColorSpace = swap_chain.format.colorSpace;
  create_info.imageExtent = swap_chain.extent;
  create_info.imageArrayLayers = 1;
  create_info.imageUsage = {.COLOR_ATTACHMENT};
  
  queue_family_indices := [len(QueueFamily)]u32{u32(queue_indices[.Graphics]), u32(queue_indices[.Present])}
  
  if queue_indices[.Graphics] != queue_indices[.Present] {
    create_info.imageSharingMode = .CONCURRENT;
    create_info.queueFamilyIndexCount = 2;
    create_info.pQueueFamilyIndices = &queue_family_indices[0];
  }
  else {
    create_info.imageSharingMode = .EXCLUSIVE;
    create_info.queueFamilyIndexCount = 0;
    create_info.pQueueFamilyIndices = nil;
  }
  
  create_info.preTransform = capabilities.currentTransform;
  create_info.compositeAlpha = {.OPAQUE};
  create_info.presentMode = swap_chain.present_mode;
  create_info.clipped = true;
  create_info.oldSwapchain = vk.SwapchainKHR{};
  
  if res := vk.CreateSwapchainKHR(device, &create_info, nil, &swap_chain.handle); res != .SUCCESS
  {
    fmt.eprintf("Error: failed to create swap chain!\n");
    os.exit(1);
  }
  
  vk.GetSwapchainImagesKHR(device, swap_chain.handle, &swap_chain.image_count, nil);
  swap_chain.images = make([]vk.Image, swap_chain.image_count);
  vk.GetSwapchainImagesKHR(device, swap_chain.handle, &swap_chain.image_count, raw_data(swap_chain.images));
}

create_image_views :: proc(using ctx: ^Context) {
  using ctx.swap_chain;
  
  image_views = make([]vk.ImageView, len(images));
  
  for _, i in images
  {
    create_info: vk.ImageViewCreateInfo;
    create_info.sType = .IMAGE_VIEW_CREATE_INFO;
    create_info.image = images[i];
    create_info.viewType = .D2;
    create_info.format = format.format;
    create_info.components.r = .IDENTITY;
    create_info.components.g = .IDENTITY;
    create_info.components.b = .IDENTITY;
    create_info.components.a = .IDENTITY;
    create_info.subresourceRange.aspectMask = {.COLOR};
    create_info.subresourceRange.baseMipLevel = 0;
    create_info.subresourceRange.levelCount = 1;
    create_info.subresourceRange.baseArrayLayer = 0;
    create_info.subresourceRange.layerCount = 1;
    
    if res := vk.CreateImageView(device, &create_info, nil, &image_views[i]); res != .SUCCESS
    {
      fmt.eprintf("Error: failed to create image view!");
      os.exit(1);
    }
  }
}

create_graphics_pipeline :: proc(ctx: ^Context, pipeline_config: ^PipelineCreateConfig, vertex_binding_desc: ^vk.VertexInputBindingDescription,
  vertex_attributes: []vk.VertexInputAttributeDescription, descriptor_layout: [^]vk.DescriptorSetLayout) -> (pipeline: Pipeline, err: Error) {
  fmt.println("Creating Graphics Pipeline...", pipeline_config.render_pass)
  // Create Shader Modules
  vs_code := compile_shader(pipeline_config.vertex_shader_filepath, .Vertex);
  fs_code := compile_shader(pipeline_config.fragment_shader_filepath, .Fragment);
  defer {
    delete(vs_code);
    delete(fs_code);
  }
  
  vs_shader := create_shader_module(ctx, vs_code);
  fs_shader := create_shader_module(ctx, fs_code);
  defer {
    vk.DestroyShaderModule(ctx.device, vs_shader, nil);
    vk.DestroyShaderModule(ctx.device, fs_shader, nil);
  }
  
  vs_info: vk.PipelineShaderStageCreateInfo;
  vs_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
  vs_info.stage = {.VERTEX};
  vs_info.module = vs_shader;
  vs_info.pName = "main";
  
  fs_info: vk.PipelineShaderStageCreateInfo;
  fs_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
  fs_info.stage = {.FRAGMENT};
  fs_info.module = fs_shader;
  fs_info.pName = "main";
  
  shader_stages := [?]vk.PipelineShaderStageCreateInfo{vs_info, fs_info};
  
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR};
  dynamic_state: vk.PipelineDynamicStateCreateInfo;
  dynamic_state.sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  dynamic_state.dynamicStateCount = len(dynamic_states);
  dynamic_state.pDynamicStates = &dynamic_states[0];
  
  vertex_input: vk.PipelineVertexInputStateCreateInfo
  vertex_input.sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
  vertex_input.vertexBindingDescriptionCount = 1
  vertex_input.pVertexBindingDescriptions = vertex_binding_desc
  vertex_input.vertexAttributeDescriptionCount = auto_cast len(vertex_attributes)
  vertex_input.pVertexAttributeDescriptions = &vertex_attributes[0]
  
  input_assembly: vk.PipelineInputAssemblyStateCreateInfo
  input_assembly.sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
  input_assembly.topology = .TRIANGLE_LIST
  input_assembly.primitiveRestartEnable = false
  
  viewport: vk.Viewport;
  viewport.x = 0.0;
  viewport.y = 0.0;
  viewport.width = cast(f32)ctx.swap_chain.extent.width;
  viewport.height = cast(f32)ctx.swap_chain.extent.height;
  viewport.minDepth = 0.0;
  viewport.maxDepth = 1.0;
  
  scissor: vk.Rect2D;
  scissor.offset = {0, 0};
  scissor.extent = ctx.swap_chain.extent;
  
  viewport_state: vk.PipelineViewportStateCreateInfo;
  viewport_state.sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  viewport_state.viewportCount = 1;
  viewport_state.scissorCount = 1;
  
  rasterizer: vk.PipelineRasterizationStateCreateInfo;
  rasterizer.sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  rasterizer.depthClampEnable = false;
  rasterizer.rasterizerDiscardEnable = false;
  rasterizer.polygonMode = .FILL;
  rasterizer.lineWidth = 1.0;
  rasterizer.cullMode = {.BACK};
  rasterizer.frontFace = .CLOCKWISE;
  rasterizer.depthBiasEnable = false;
  rasterizer.depthBiasConstantFactor = 0.0;
  rasterizer.depthBiasClamp = 0.0;
  rasterizer.depthBiasSlopeFactor = 0.0;
  
  multisampling: vk.PipelineMultisampleStateCreateInfo;
  multisampling.sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  multisampling.sampleShadingEnable = false;
  multisampling.rasterizationSamples = {._1};
  multisampling.minSampleShading = 1.0;
  multisampling.pSampleMask = nil;
  multisampling.alphaToCoverageEnable = false;
  multisampling.alphaToOneEnable = false;
  
  color_blend_attachment: vk.PipelineColorBlendAttachmentState;
  color_blend_attachment.colorWriteMask = {.R, .G, .B, .A};
  color_blend_attachment.blendEnable = true;
  color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA;
  color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
  color_blend_attachment.colorBlendOp = .ADD;
  color_blend_attachment.srcAlphaBlendFactor = .ONE;
  color_blend_attachment.dstAlphaBlendFactor = .ZERO;
  color_blend_attachment.alphaBlendOp = .ADD;
  
  color_blending: vk.PipelineColorBlendStateCreateInfo;
  color_blending.sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
  color_blending.logicOpEnable = false;
  color_blending.logicOp = .COPY;
  color_blending.attachmentCount = 1;
  color_blending.pAttachments = &color_blend_attachment;
  color_blending.blendConstants[0] = 0.0;
  color_blending.blendConstants[1] = 0.0;
  color_blending.blendConstants[2] = 0.0;
  color_blending.blendConstants[3] = 0.0;
  
  // Create Pipeline Layout
  pipeline_layout_info: vk.PipelineLayoutCreateInfo;
  pipeline_layout_info.sType = .PIPELINE_LAYOUT_CREATE_INFO;
  pipeline_layout_info.setLayoutCount = 1;
  pipeline_layout_info.pSetLayouts = descriptor_layout
  pipeline_layout_info.pushConstantRangeCount = 0;
  pipeline_layout_info.pPushConstantRanges = nil;
  
  if res := vk.CreatePipelineLayout(ctx.device, &pipeline_layout_info, nil, &pipeline.layout); res != .SUCCESS
  {
    fmt.eprintf("Error: Failed to create pipeline layout!\n");
    err = .NotYetDetailed
    return
  }

  depth_stencil_create_info := vk.PipelineDepthStencilStateCreateInfo {
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    depthWriteEnable = true,
    depthCompareOp = .LESS,
    depthBoundsTestEnable = false,
    minDepthBounds = 0.0,
    maxDepthBounds = 1.0,
    stencilTestEnable = false,
  }

  // Create Pipeline
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount = 2,
    pStages = &shader_stages[0],
    pVertexInputState = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState = &multisampling,
    pColorBlendState = &color_blending,
    pDynamicState = &dynamic_state,
    layout = pipeline.layout,
    subpass = 0,
    basePipelineHandle = vk.Pipeline{},
    basePipelineIndex = -1,
  }

  render_pass: ^RenderPass = get_resource(&ctx.resource_manager, pipeline_config.render_pass) or_return
  pipeline_info.renderPass = render_pass.render_pass
  if .HasDepthBuffer in render_pass.config {
    pipeline_info.pDepthStencilState = &depth_stencil_create_info
  }
  
  if res := vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_info, nil, &pipeline.handle); res != .SUCCESS {
    fmt.eprintf("Error: Failed to create graphics pipeline!\n")
    err = .NotYetDetailed
    return
  }

  return
}

create_shader_module :: proc(using ctx: ^Context, code: []u8) -> vk.ShaderModule {
  create_info: vk.ShaderModuleCreateInfo;
  create_info.sType = .SHADER_MODULE_CREATE_INFO;
  create_info.codeSize = len(code);
  create_info.pCode = cast(^u32)raw_data(code);
  
  shader: vk.ShaderModule;
  if res := vk.CreateShaderModule(device, &create_info, nil, &shader); res != .SUCCESS
  {
    fmt.eprintf("Error: Could not create shader module!\n");
    os.exit(1);
  }
  
  return shader;
}

create_command_pool :: proc(using ctx: ^Context) -> Error {
  pool_info: vk.CommandPoolCreateInfo
  pool_info.sType = .COMMAND_POOL_CREATE_INFO;
  pool_info.flags = {.RESET_COMMAND_BUFFER};
  pool_info.queueFamilyIndex = u32(queue_indices[.Graphics]);
  
  vkres := vk.CreateCommandPool(device, &pool_info, nil, &command_pool)
  if vkres != .SUCCESS {
    fmt.eprintf("Error: Failed to create command pool:", vkres);
    return .NotYetDetailed
  }

  return .Success
}

create_command_buffers :: proc(using ctx: ^Context) -> Error {
  alloc_info := vk.CommandBufferAllocateInfo {
    sType = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool = command_pool,
    level = .PRIMARY,
    commandBufferCount = MAX_FRAMES_IN_FLIGHT,
  }
  
  swap_chain.command_buffers = make([]vk.CommandBuffer, MAX_FRAMES_IN_FLIGHT)
  if res := vk.AllocateCommandBuffers(device, &alloc_info, &swap_chain.command_buffers[0]); res != .SUCCESS {
    fmt.eprintf("Error: Failed to allocate command buffers!\n");
    return .NotYetDetailed
  }

  // Single-Time Command Buffer
  alloc_info = vk.CommandBufferAllocateInfo {
    sType = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool = command_pool,
    level = .PRIMARY,
    commandBufferCount = 1,
  }

  vkres := vk.AllocateCommandBuffers(ctx.device, &alloc_info, &st_command_buffer)
  if vkres != .SUCCESS {
    fmt.eprintln("vk.AllocateCommandBuffer st_command_buffer failed:", vkres)
    return .NotYetDetailed
  }

  return .Success
}

record_command_buffer :: proc(using ctx: ^Context, buffer: vk.CommandBuffer, image_index: u32) {
  fmt.eprintln("record_command_buffer Not using this no more")
  os.exit(1)
  // begin_info: vk.CommandBufferBeginInfo;
  // begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
  // begin_info.flags = {};
  // begin_info.pInheritanceInfo = nil;
  
  // if res := vk.BeginCommandBuffer(buffer,  &begin_info); res != .SUCCESS
  // {
  //   fmt.eprintf("Error: Failed to begin recording command buffer!\n");
  //   os.exit(1);
  // }
  
  // render_pass_info: vk.RenderPassBeginInfo;
  // render_pass_info.sType = .RENDER_PASS_BEGIN_INFO;
  // render_pass_info.renderPass = present_render_pass;
  // render_pass_info.framebuffer = swap_chain.present_framebuffers[image_index];
  // render_pass_info.renderArea.offset = {0, 0};
  // render_pass_info.renderArea.extent = swap_chain.extent;
  
  // clear_color: vk.ClearValue;
  // clear_color.color.float32 = [4]f32{0.0, 0.0, 0.0, 1.0};
  // render_pass_info.clearValueCount = 1;
  // render_pass_info.pClearValues = &clear_color;
  
  // vk.CmdBeginRenderPass(buffer, &render_pass_info, .INLINE);
  
  // vk.CmdBindPipeline(buffer, .GRAPHICS, pipeline.handle);
  
  // vertex_buffers := [?]vk.Buffer{vertex_buffer.buffer};
  // offsets := [?]vk.DeviceSize{0};
  // vk.CmdBindVertexBuffers(buffer, 0, 1, &vertex_buffers[0], &offsets[0]);
  // vk.CmdBindIndexBuffer(buffer, index_buffer.buffer, 0, .UINT16);
  
  // viewport: vk.Viewport;
  // viewport.x = 0.0;
  // viewport.y = 0.0;
  // viewport.width = f32(swap_chain.extent.width);
  // viewport.height = f32(swap_chain.extent.height);
  // viewport.minDepth = 0.0;
  // viewport.maxDepth = 1.0;
  // vk.CmdSetViewport(buffer, 0, 1, &viewport);
  
  // scissor: vk.Rect2D;
  // scissor.offset = {0, 0};
  // scissor.extent = swap_chain.extent;
  // vk.CmdSetScissor(buffer, 0, 1, &scissor);
  
  // vk.CmdDrawIndexed(buffer, cast(u32)index_buffer.length, 1, 0, 0, 0);
  
  // vk.CmdEndRenderPass(buffer);
  
  // if res := vk.EndCommandBuffer(buffer); res != .SUCCESS
  // {
  //   fmt.eprintf("Error: Failed to record command buffer!\n");
  //   os.exit(1);
  // }
}

create_sync_objects :: proc(using ctx: ^Context) -> Error {
  semaphore_info: vk.SemaphoreCreateInfo;
  semaphore_info.sType = .SEMAPHORE_CREATE_INFO;
  
  fence_info: vk.FenceCreateInfo;
  fence_info.sType = .FENCE_CREATE_INFO;
  fence_info.flags = {.SIGNALED}
  
  for i in 0..<MAX_FRAMES_IN_FLIGHT
  {
    res := vk.CreateSemaphore(device, &semaphore_info, nil, &_render_contexts[i].image_available);
    if res != .SUCCESS
    {
      fmt.eprintf("Error: Failed to create \"image_available\" semaphore\n");
      return .NotYetDetailed
    }
    res = vk.CreateSemaphore(device, &semaphore_info, nil, &_render_contexts[i].render_finished);
    if res != .SUCCESS
    {
      fmt.eprintf("Error: Failed to create \"render_finished\" semaphore\n");
      return .NotYetDetailed
    }
    res = vk.CreateFence(device, &fence_info, nil, &_render_contexts[i].in_flight);
    if res != .SUCCESS
    {
      fmt.eprintf("Error: Failed to create \"in_flight\" fence\n");
      return .NotYetDetailed
    }
  }

  return .Success
}

recreate_swap_chain :: proc(using ctx: ^Context) {
  width, height := get_window_size(window)
  for width == 0 && height == 0
  {
    width, height = get_window_size(window)
  }
  vk.DeviceWaitIdle(device);
  
  cleanup_swap_chain(ctx);
  
  create_swap_chain(ctx);
  create_image_views(ctx);
  
  _resize_framebuffer_resources(ctx)
}

cleanup_swap_chain :: proc(using ctx: ^Context) {
  for view in swap_chain.image_views
  {
    vk.DestroyImageView(device, view, nil);
  }
  vk.DestroySwapchainKHR(device, swap_chain.handle, nil);
}

// TODO -- not used?
copy_buffer :: proc(using ctx: ^Context, src, dst: Buffer, size: vk.DeviceSize) {
  alloc_info := vk.CommandBufferAllocateInfo{
    sType = .COMMAND_BUFFER_ALLOCATE_INFO,
    level = .PRIMARY,
    commandPool = command_pool,
    commandBufferCount = 1,
  };
  
  cmd_buffer: vk.CommandBuffer;
  vk.AllocateCommandBuffers(device, &alloc_info, &cmd_buffer);
  
  begin_info := vk.CommandBufferBeginInfo{
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  
  vk.BeginCommandBuffer(cmd_buffer, &begin_info);
  
  copy_region := vk.BufferCopy{
    srcOffset = 0,
    dstOffset = 0,
    size = size,
  }
  vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &copy_region);
  vk.EndCommandBuffer(cmd_buffer);
  
  submit_info := vk.SubmitInfo{
    sType = .SUBMIT_INFO,
    commandBufferCount = 1,
    pCommandBuffers = &cmd_buffer,
  };
  
  vk.QueueSubmit(queues[.Graphics], 1, &submit_info, {});
  vk.QueueWaitIdle(queues[.Graphics]);
  vk.FreeCommandBuffers(device, command_pool, 1, &cmd_buffer);
}

// TODO -- not used?
find_memory_type :: proc(using ctx: ^Context, type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
  mem_properties: vk.PhysicalDeviceMemoryProperties;
  vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);
  for i in 0..<mem_properties.memoryTypeCount
  {
    if (type_filter & (1 << i) != 0) && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties
    {
      return i;
    }
  }
  
  fmt.eprintf("Error: Failed to find suitable memory type!\n");
  os.exit(1);
}

// Depends on init_uniform_buffer() and init_descriptor_and_pipeline_layouts() TODO ?
_init_descriptor_pool :: proc(using ctx: ^Context) -> Error {
  DESCRIPTOR_POOL_COUNT :: 2

  type_count := [DESCRIPTOR_POOL_COUNT]vk.DescriptorPoolSize {
    vk.DescriptorPoolSize {
      type = .UNIFORM_BUFFER,
      descriptorCount = 4096,
    },
    vk.DescriptorPoolSize {
      type = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 2048,
    },
  }

  descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
    sType = .DESCRIPTOR_POOL_CREATE_INFO,
    maxSets = MAX_DESCRIPTOR_SETS,
    poolSizeCount = DESCRIPTOR_POOL_COUNT,
    pPoolSizes = &type_count[0],
  }

  for i in 0..<MAX_FRAMES_IN_FLIGHT {
    vkres := vk.CreateDescriptorPool(ctx.device, &descriptor_pool_create_info, nil, & _render_contexts[i].descriptor_pool)
    if vkres != .SUCCESS {
      fmt.eprintln("vkCreateDescriptorPool:", vkres)
      return .NotYetDetailed
    }
  }

  return .Success
}

create_render_pass :: proc(using ctx: ^Context, config: RenderPassConfigFlags) -> (rh: RenderPassResourceHandle, err: Error) {
  rh = auto_cast _create_resource(&ctx.resource_manager, .RenderPass) or_return
  rp: ^RenderPass = auto_cast get_resource(&ctx.resource_manager, auto_cast rh) or_return
  rp.config = config

  has_depth_buffer := .HasDepthBuffer in config
  if has_depth_buffer {
    _create_depth_buffer(ctx, rp) or_return
  }

  // Attachments
  attachments := [2]vk.AttachmentDescription {
    vk.AttachmentDescription {
      format = swap_chain.format.format,
      samples = {._1},
      loadOp = (.HasPreviousColorPass in config) ? .LOAD : .CLEAR,
      storeOp = .STORE,
      stencilLoadOp = .DONT_CARE,
      stencilStoreOp = .DONT_CARE,
      initialLayout = (.HasPreviousColorPass in config) ? .COLOR_ATTACHMENT_OPTIMAL : .UNDEFINED,
      finalLayout = (.IsPresent in config) ? .PRESENT_SRC_KHR : .COLOR_ATTACHMENT_OPTIMAL,
    },
    vk.AttachmentDescription {
      format = has_depth_buffer ? rp.depth_buffer.format : .UNDEFINED,
      samples = {._1},
      loadOp = .CLEAR,
      storeOp = .DONT_CARE,
      stencilLoadOp = .DONT_CARE,
      stencilStoreOp = .DONT_CARE,
      initialLayout = .UNDEFINED,
      finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    },
  }
    
  color_attachment_ref: vk.AttachmentReference
  color_attachment_ref.attachment = 0
  color_attachment_ref.layout = .COLOR_ATTACHMENT_OPTIMAL

  depth_attachment_ref: vk.AttachmentReference
  depth_attachment_ref.attachment = 1
  depth_attachment_ref.layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
  
  // Subpass
  subpass := vk.SubpassDescription {
    pipelineBindPoint = .GRAPHICS,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment_ref,
    pDepthStencilAttachment = has_depth_buffer ? &depth_attachment_ref : nil,
  }

  dependencies := [2]vk.SubpassDependency {
    vk.SubpassDependency {
      srcSubpass = vk.SUBPASS_EXTERNAL,
      dstSubpass = 0,
      srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
      srcAccessMask = {},
      dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
    },
    vk.SubpassDependency {
      srcSubpass = vk.SUBPASS_EXTERNAL,
      dstSubpass = 0,
      srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
      srcAccessMask = {},
      dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
      dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    },
    // TODO srcSubpass = 0, dstSubpass = vk.SUBPASS_EXTERNAL, ???
  }
  
  // Create Render Pass
  render_pass_info: vk.RenderPassCreateInfo;
  render_pass_info.sType = .RENDER_PASS_CREATE_INFO;
  render_pass_info.attachmentCount = has_depth_buffer ? 2 : 1
  render_pass_info.pAttachments = &attachments[0];
  render_pass_info.subpassCount = 1;
  render_pass_info.pSubpasses = &subpass;
  render_pass_info.dependencyCount = has_depth_buffer ? 2 : 1
  render_pass_info.pDependencies = &dependencies[0];
  
  if res := vk.CreateRenderPass(ctx.device, &render_pass_info, nil, &rp.render_pass); res != .SUCCESS {
    fmt.eprintf("Error: Failed to create render pass!\n");
    err = .NotYetDetailed
    return
  }

  res := _create_framebuffers(ctx, rp)
  if res != .Success {
    destroy_render_pass(ctx, rh)
    err = .NotYetDetailed
    return
  }
  
  return
}

_create_framebuffers :: proc(using ctx: ^Context, rp: ^RenderPass) -> Error {
  rp_has_depth_buffer := (rp.depth_buffer_rh == 0) ? false : true
  rp.framebuffers = make([]vk.Framebuffer, len(swap_chain.image_views))
  for v, i in swap_chain.image_views {
    attachments := [?]vk.ImageView{v, rp_has_depth_buffer ? rp.depth_buffer.view : 0}

    framebuffer_create_info := vk.FramebufferCreateInfo {
      sType = .FRAMEBUFFER_CREATE_INFO,
      renderPass = rp.render_pass,
      attachmentCount = rp_has_depth_buffer ? 2 : 1,
      pAttachments = &attachments[0],
      width = swap_chain.extent.width,
      height = swap_chain.extent.height,
      layers = 1,
    }
    
    if res := vk.CreateFramebuffer(device, &framebuffer_create_info, nil, &rp.framebuffers[i]); res != .SUCCESS
    {
      fmt.eprintln("Error: Failed to create framebuffer:", res)
      return .NotYetDetailed
    }
  }
  fmt.println("TODO framebuffer resizing")

  return .Success
}

// VkImageTiling image_tiling, VkFormatFeatureFlagBits features, VkFormat *result)
_find_supported_format :: proc(ctx: ^Context, preferred_formats: []vk.Format, image_tiling: vk.ImageTiling,
  features: vk.FormatFeatureFlags) -> vk.Format {
  
  props: vk.FormatProperties
  for i in 0..<len(preferred_formats) {
    vk.GetPhysicalDeviceFormatProperties(ctx.physical_device, preferred_formats[i], &props)

    // TODO check <= means in and not less-than-or-equal-to IN THIS CASE
    // fmt.println("CHECK props.linearTilingFeatures:", props.linearTilingFeatures, "props.optimalTilingFeatures:",
    //   props.optimalTilingFeatures, "features:", features)
    if image_tiling == .LINEAR && features <= props.linearTilingFeatures {
      return preferred_formats[i]
    } else if image_tiling == .OPTIMAL && features <= props.optimalTilingFeatures {
      // fmt.println("using preferred depth format:", preferred_formats[i])
      return preferred_formats[i]
    }
  }

  return .UNDEFINED
}

_create_depth_buffer :: proc(ctx: ^Context, rp: ^RenderPass) -> Error {
  preferred_depth_formats := [?]vk.Format {
    .D32_SFLOAT,
    .D32_SFLOAT_S8_UINT,
    .D24_UNORM_S8_UINT,
  }

  // Create the depth buffer resource
  rp.depth_buffer_rh = _create_resource(&ctx.resource_manager, .DepthBuffer) or_return
  rp.depth_buffer = auto_cast get_resource(&ctx.resource_manager, rp.depth_buffer_rh) or_return

  // Fill it out
  rp.depth_buffer.format = _find_supported_format(ctx, preferred_depth_formats[:], .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT})
  if rp.depth_buffer.format == .UNDEFINED {
    fmt.println("Error: Failed to find supported depth format")
    return .NotYetDetailed
  }

  // Color attachment
  image_create_info := vk.ImageCreateInfo {
    sType = .IMAGE_CREATE_INFO,
    imageType = .D2,
    format = rp.depth_buffer.format,
    extent = vk.Extent3D {
      width = ctx.swap_chain.extent.width,
      height = ctx.swap_chain.extent.height,
      depth = 1,
    },
    mipLevels = 1,
    arrayLayers = 1,
    samples = {._1},
    tiling = .OPTIMAL,
    usage = {.DEPTH_STENCIL_ATTACHMENT},
  }
  
  vkres := vk.CreateImage(ctx.device, &image_create_info, nil, &rp.depth_buffer.image)
  if vkres != .SUCCESS {
    fmt.println("Error: Failed to create depth buffer image:", vkres)
    return .NotYetDetailed
  }
  
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(ctx.device, rp.depth_buffer.image, &mem_requirements)

  alloc_info := vk.MemoryAllocateInfo {
    sType = .MEMORY_ALLOCATE_INFO,
    allocationSize = mem_requirements.size,
    memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL}),
  }
  
  vkres = vk.AllocateMemory(ctx.device, &alloc_info, nil, &rp.depth_buffer.memory)
  if vkres != .SUCCESS {
    fmt.println("Error: Failed to allocate depth buffer memory:", vkres)
    return .NotYetDetailed
  }

  vkres = vk.BindImageMemory(ctx.device, rp.depth_buffer.image, rp.depth_buffer.memory, 0)
  if vkres != .SUCCESS {
    fmt.println("Error: Failed to bind depth buffer memory:", vkres)
    return .NotYetDetailed
  }

  color_image_view_create_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    viewType = .D2,
    format = rp.depth_buffer.format,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    image = rp.depth_buffer.image,
  }
  vkres = vk.CreateImageView(ctx.device, &color_image_view_create_info, nil, &rp.depth_buffer.view)
  if vkres != .SUCCESS {
    fmt.println("Error: Failed to create depth buffer image view:", vkres)
    return .NotYetDetailed
  }

  // TODO create these with vma
  
  return .Success
}