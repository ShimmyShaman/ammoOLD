package violin

import "core:os"
import "core:fmt"
import "core:c/libc"
import "core:mem"
import "core:sync"

import vk "vendor:vulkan"
// import stb "vendor:stb/lib"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"
import vma "../deps/odin-vma"

// https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/usage_patterns.html
BufferUsage :: enum {
  Null = 0,
  // When: Any resources that you frequently write and read on GPU, e.g. images used as color attachments (aka "render targets"),
  //   depth-stencil attachments, images/buffers used as storage image/buffer (aka "Unordered Access View (UAV)").
  GpuOnlyDedicated,
  // When: A "staging" buffer than you want to map and fill from CPU code, then use as a source od transfer to some GPU resource.
  Staged,
  // When: Buffers for data written by or transferred from the GPU that you want to read back on the CPU, e.g. results of some computations.
  Readback,
  // When: Resources that you frequently write on CPU via mapped pointer and frequently read on GPU e.g. as a uniform buffer (also called "dynamic")
  Dynamic,
  // DeviceBuffer,
  // TODO -- the 'other use cases'
}

ResourceHandle :: distinct int
TextureResourceHandle :: distinct ResourceHandle
VertexBufferResourceHandle :: distinct ResourceHandle
IndexBufferResourceHandle :: distinct ResourceHandle
RenderPassResourceHandle :: distinct ResourceHandle
StampRenderResourceHandle :: distinct ResourceHandle
FontResourceHandle :: distinct ResourceHandle

ResourceKind :: enum {
  Buffer = 1,
  Texture,
  DepthBuffer,
  RenderPass,
  StampRenderResource,
  VertexBuffer,
  IndexBuffer,
  Font,
}

Resource :: struct {
  kind: ResourceKind,
  data: union {
    Buffer,
    Texture,
    DepthBuffer,
    RenderPass,
    StampRenderResource,
    VertexBuffer,
    IndexBuffer,
    Font,
  },
}

ImageUsage :: enum {
  ShaderReadOnly = 1,
  // ColorAttachment,
  // DepthStencilAttachment,
  // RenderTarget,
  // Present_KHR,
}

Buffer :: struct {
  buffer: vk.Buffer,
  allocation: vma.Allocation,
  allocation_info: vma.AllocationInfo,
  size:   vk.DeviceSize,
}

Texture :: struct {
  sampler_usage: ImageUsage,
  width: u32,
  height: u32,
  size:   vk.DeviceSize,
  // format: vk.Format,
  image: vk.Image,
  // image_memory: vk.DeviceMemory,
  image_view: vk.ImageView,
  // framebuffer: vk.Framebuffer,
  sampler: vk.Sampler,
  allocation: vma.Allocation,
  allocation_info: vma.AllocationInfo,

  format: vk.Format,
  current_layout: vk.ImageLayout,
  intended_usage: ImageUsage,
}

DepthBuffer :: struct {
  format: vk.Format,
  image: vk.Image,
  memory: vk.DeviceMemory,
  view: vk.ImageView,
}

VertexBuffer :: struct {
  using _buf: Buffer,
  vertices: ^f32, // TODO -- REMOVE THIS ?
  vertex_count: int,
}

IndexBuffer :: struct {
  using _buf: Buffer,
  indices: rawptr, // TODO -- REMOVE THIS ?
  index_count: int,
  index_type: vk.IndexType,
}

RenderPass :: struct {
  config: RenderPassConfigFlags,
  render_pass: vk.RenderPass, // TODO change to vk_handle
  framebuffers: []vk.Framebuffer,
  depth_buffer: ^DepthBuffer,
  depth_buffer_rh: ResourceHandle,
}

StampRenderResource :: struct {
  // clear_render_pass, draw_render_pass, present_render_pass: RenderPassResourceHandle,
  render_pass: RenderPassResourceHandle,
  colored_rect_render_program, textured_rect_render_program: RenderProgram,
  colored_rect_vertex_buffer, textured_rect_vertex_buffer: VertexBufferResourceHandle,
  rect_index_buffer: IndexBufferResourceHandle,

  uniform_buffer: StampUniformBuffer,
}

StampUniformBuffer :: struct {
  rh: ResourceHandle,
  utilization: vk.DeviceSize,
  capacity: vk.DeviceSize,
  device_min_block_alignment: vk.DeviceSize,
}

Font :: struct {
  name: string,
  height: f32,
  draw_vertical_offset: f32,
  texture: TextureResourceHandle,
  char_data: [^]stbtt.bakedchar,
}

// TODO -- this is a bit of a hack, but it works for now
// Allocated memory is disconjugate and not reusable
RESOURCE_BUCKET_SIZE :: 32
ResourceManager :: struct {
  _mutex: sync.Mutex,
  resource_index: ResourceHandle,
  resource_map: map[ResourceHandle]^Resource,
}

InputAttribute :: struct
{
  format: vk.Format,
  location: u32,
  offset: u32,
}

PipelineCreateConfig :: struct {
  render_pass: RenderPassResourceHandle,
  vertex_shader_filepath: string,
  fragment_shader_filepath: string,
}

RenderProgramCreateInfo :: struct {
  pipeline_config: PipelineCreateConfig,
  vertex_size: int,
  buffer_bindings: []vk.DescriptorSetLayoutBinding,
  input_attributes: []InputAttribute,
}

RenderProgram :: struct {
  layout_bindings: []vk.DescriptorSetLayoutBinding,
	pipeline: Pipeline,
  descriptor_layout: vk.DescriptorSetLayout,
}

_init_resource_manager :: proc(using rm: ^ResourceManager) -> Error {
  resource_index = 1000
  resource_map = make(map[ResourceHandle]^Resource)

  return .Success
}

// TODO -- ? remove size ? not used at all
_create_resource :: proc(using rm: ^ResourceManager, resource_kind: ResourceKind, size: u32 = 0) -> (rh: ResourceHandle, err: Error) {
  sync.lock(&rm._mutex)
  defer sync.unlock(&rm._mutex)

  switch resource_kind {
    case .Texture, .Buffer, .DepthBuffer, .RenderPass, .StampRenderResource, .VertexBuffer, .IndexBuffer,
      .Font:
      rh = resource_index
      resource_index += 1
      res : ^Resource = auto_cast mem.alloc(size_of(Resource))
      resource_map[rh] = res
      res.kind = resource_kind
      // fmt.println("Created resource: ", rh)
      return
    case:
      fmt.println("Resource type not supported:", resource_kind)
      err = .NotYetDetailed
      return
  }
}

_resource_manager_report :: proc(using rm: ^ResourceManager) {
  fmt.println("Resource Manager Report:")
  // fmt.println("  Resource Manager:", rm)
  fmt.println("  Resource Count: ", len(resource_map))
  fmt.println("  Resource Index: ", resource_index)
}

_get_resource :: proc(using rm: ^ResourceManager, rh: ResourceHandle, loc := #caller_location) -> (ptr: rawptr, err: Error) {
  res := resource_map[rh]
  if res == nil {
    err = .ResourceNotFound
    fmt.eprintln("Could not find resource for handle:", rh)
    fmt.eprintln("--Caller:", loc)
    _resource_manager_report(rm)
    return
  }

  ptr = &res.data
  return
}

get_resource_render_pass :: proc(using rm: ^ResourceManager, rh: RenderPassResourceHandle, loc := #caller_location) -> (ptr: ^RenderPass, err: Error) {
  ptr = auto_cast _get_resource(rm, auto_cast rh, loc) or_return
  return
}

get_resource :: proc {_get_resource, get_resource_render_pass}

destroy_resource_any :: proc(using ctx: ^Context, rh: ResourceHandle) -> Error {
  vk.DeviceWaitIdle(ctx.device)
  
  res := resource_manager.resource_map[rh]
  if res == nil {
    fmt.println("Resource not found:", rh)
    return .ResourceNotFound
  }

  switch res.kind {
    case .Texture:
      texture : ^Texture = auto_cast &res.data
      vma.DestroyImage(vma_allocator, texture.image, texture.allocation)
      if texture.image_view != 0 {
        vk.DestroyImageView(ctx.device, texture.image_view, nil)
      }
      if texture.sampler != 0 {
        vk.DestroySampler(ctx.device, texture.sampler, nil)
      }
    case .Buffer:
      buffer : ^Buffer = auto_cast &res.data
      vma.DestroyBuffer(vma_allocator, buffer.buffer, buffer.allocation)
    case .RenderPass:
      render_pass: ^RenderPass = auto_cast &res.data
      
      if render_pass.framebuffers != nil {
        for i in 0..<len(render_pass.framebuffers) {
          vk.DestroyFramebuffer(ctx.device, render_pass.framebuffers[i], nil)
        }
        delete_slice(render_pass.framebuffers)
      }

      if render_pass.depth_buffer_rh > 0 {
        destroy_resource(ctx, render_pass.depth_buffer_rh)
      }

      vk.DestroyRenderPass(device, render_pass.render_pass, nil)
    case .DepthBuffer:
      db: ^DepthBuffer = auto_cast &res.data

      vk.DestroyImageView(device, db.view, nil)
      vk.DestroyImage(device, db.image, nil)
      vk.FreeMemory(device, db.memory, nil)
    case .StampRenderResource:
      tdr: ^StampRenderResource = auto_cast &res.data

      __release_stamp_render_resource(ctx, tdr)
    case .VertexBuffer, .IndexBuffer:
      vb: ^VertexBuffer = auto_cast &res.data
      
      vma.DestroyBuffer(vma_allocator, vb.buffer, vb.allocation)
    case .Font:
      font: ^Font = auto_cast &res.data

      destroy_resource(ctx, font.texture)
      // TODO char_data
    case:
      fmt.println("Resource type not supported:", res.kind)
      return .NotYetDetailed
  }

  delete_key(&resource_manager.resource_map, rh)
  // fmt.println("Destroyed resource:", rh, "of type:", res.kind)
  // if render_data.texture.image != 0 {
  //   vk.DestroyImage(ctx.device, render_data.texture.image, nil)
  //   vk.FreeMemory(ctx.device, render_data.texture.image_memory, nil)
  //   vk.DestroyImageView(ctx.device, render_data.texture.image_view, nil)
  //   vk.DestroySampler(ctx.device, render_data.texture.sampler, nil)
  // }
  return .Success
}

destroy_render_pass :: proc(using ctx: ^Context, rh: RenderPassResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_texture :: proc(using ctx: ^Context, rh: TextureResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_vertex_buffer :: proc(using ctx: ^Context, rh: VertexBufferResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_index_buffer :: proc(using ctx: ^Context, rh: IndexBufferResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_ui_render_resource :: proc(using ctx: ^Context, rh: StampRenderResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_font :: proc(using ctx: ^Context, rh: FontResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_resource :: proc {destroy_resource_any, destroy_render_pass, destroy_texture, destroy_vertex_buffer, destroy_index_buffer,
  destroy_ui_render_resource, destroy_font}

_resize_framebuffer_resources :: proc(using ctx: ^Context) -> Error {

  fmt.println("Resizing framebuffer resources TODO")

  return .NotYetImplemented
  // for f in swap_chain.present_framebuffers
  // {
  //   vk.DestroyFramebuffer(device, f, nil);
  // }
  // for f in swap_chain.framebuffers_3d
  // {
  //   vk.DestroyFramebuffer(device, f, nil);
  // }
  // _create_framebuffers(ctx);
}

_begin_single_time_commands :: proc(ctx: ^Context) -> Error {
  // -- Reset the Command Buffer
  vkres := vk.ResetCommandBuffer(ctx.st_command_buffer, {})
  if vkres != .SUCCESS {
    fmt.eprintln("Error: Failed to reset command buffer:", vkres)
    return .NotYetDetailed
  }

  // Begin it
  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = { .ONE_TIME_SUBMIT },
  }
  
  vkres = vk.BeginCommandBuffer(ctx.st_command_buffer, &begin_info)
  if vkres != .SUCCESS {
    fmt.eprintln("vk.BeginCommandBuffer failed:", vkres)
    return .NotYetDetailed
  }
  
  return .Success
}

_end_single_time_commands :: proc(ctx: ^Context) -> Error {
  // End
  vkres := vk.EndCommandBuffer(ctx.st_command_buffer)
  if vkres != .SUCCESS {
    fmt.eprintln("vk.EndCommandBuffer failed:", vkres)
    return .NotYetDetailed
  }

  // Submit to queue
  submit_info := vk.SubmitInfo {
    sType = .SUBMIT_INFO,
    commandBufferCount = 1,
    pCommandBuffers = &ctx.st_command_buffer,
  }
  vkres = vk.QueueSubmit(ctx.queues[.Graphics], 1, &submit_info, auto_cast 0)
  if vkres != .SUCCESS {
    fmt.eprintln("vk.QueueSubmit failed:", vkres)
    return .NotYetDetailed
  }

  vkres = vk.QueueWaitIdle(ctx.queues[.Graphics])
  if vkres != .SUCCESS {
    fmt.eprintln("vk.QueueWaitIdle failed:", vkres)
    return .NotYetDetailed
  }

  return .Success
}

transition_image_layout :: proc(ctx: ^Context, image: vk.Image, format: vk.Format, old_layout: vk.ImageLayout,
  new_layout: vk.ImageLayout) -> Error {
    
  _begin_single_time_commands(ctx) or_return

  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = new_layout,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = { .COLOR },
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  
  source_stage: vk.PipelineStageFlags
  destination_stage: vk.PipelineStageFlags
  
  if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
    barrier.srcAccessMask = {}
    barrier.dstAccessMask = { .TRANSFER_WRITE }
    
    source_stage = { .TOP_OF_PIPE }
    destination_stage = { .TRANSFER }
  } else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
    barrier.srcAccessMask = { .TRANSFER_WRITE }
    barrier.dstAccessMask = { .SHADER_READ }
    
    source_stage = { .TRANSFER }
    destination_stage = { .FRAGMENT_SHADER } // TODO -- VertexShader?
  } else {
    fmt.eprintln("ERROR transition_image_layout> unsupported layout transition:", old_layout, "to", new_layout)
    return .NotYetDetailed
  }
  
  vk.CmdPipelineBarrier(ctx.st_command_buffer, source_stage, destination_stage, {}, 0, nil, 0, nil, 1, &barrier)
  
  _end_single_time_commands(ctx) or_return

  return .Success
}

write_to_texture :: proc(using ctx: ^Context, dst: TextureResourceHandle, data: rawptr, size_in_bytes: int) -> Error {
  texture: ^Texture = auto_cast _get_resource(&resource_manager, auto_cast dst) or_return

  // Transition Image Layout
  transition_image_layout(ctx, texture.image, texture.format, texture.current_layout, .TRANSFER_DST_OPTIMAL) or_return

  // Get the created buffers memory properties
  mem_property_flags: vk.MemoryPropertyFlags
  vma.GetAllocationMemoryProperties(vma_allocator, texture.allocation, &mem_property_flags)
  
  if vk.MemoryPropertyFlag.HOST_VISIBLE in mem_property_flags {
    // Allocation ended up in a mappable memory and is already mapped - write to it directly.
    // [Executed in runtime]:
    mem.copy(texture.allocation_info.pMappedData, data, size_in_bytes)
  } else {
    // Create a staging buffer
    staging_buffer_create_info := vk.BufferCreateInfo {
      sType = .BUFFER_CREATE_INFO,
      size = auto_cast size_in_bytes,
      usage = {.TRANSFER_SRC},
    }

    staging_allocation_create_info := vma.AllocationCreateInfo {
      usage = .AUTO,
      flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
    }
    
    staging: Buffer
    vkres := vma.CreateBuffer(vma_allocator, &staging_buffer_create_info, &staging_allocation_create_info, &staging.buffer,
      &staging.allocation, &staging.allocation_info)
    if vkres != .SUCCESS {
      fmt.eprintln("write_to_buffer>vmaCreateBuffer failed:", vkres)
      return .NotYetDetailed
    }
    defer vma.DestroyBuffer(vma_allocator, staging.buffer, staging.allocation)

    // Copy data to the staging buffer
    mem.copy(staging.allocation_info.pMappedData, data, size_in_bytes)

    // Copy buffers
    _begin_single_time_commands(ctx) or_return

    // copy_region := vk.BufferCopy {
    //   srcOffset = 0,
    //   dstOffset = 0,
    //   size = auto_cast size_in_bytes,
    // }
    // vk.CmdCopyBuffer(ctx.st_command_buffer, staging.buffer, buffer.buffer, 1, &copy_region)
    region := vk.BufferImageCopy {
      bufferOffset = 0,
      bufferRowLength = 0,
      bufferImageHeight = 0,
      imageSubresource = vk.ImageSubresourceLayers {
        aspectMask = { .COLOR },
        mipLevel = 0,
        baseArrayLayer = 0,
        layerCount = 1,
      },
      // imageOffset = vk.Offset3D { x = 0, y = 0, z = 0 },
      imageExtent = vk.Extent3D {
        width = texture.width,
        height = texture.height,
        depth = 1,
      },
    }
  
    vk.CmdCopyBufferToImage(ctx.st_command_buffer, staging.buffer, texture.image, .TRANSFER_DST_OPTIMAL, 1, &region)

    _end_single_time_commands(ctx) or_return
  }

  // Transition Image Layout
  target_layout: vk.ImageLayout
  switch texture.intended_usage {
    case .ShaderReadOnly:
      target_layout = .SHADER_READ_ONLY_OPTIMAL
  }
  transition_image_layout(ctx, texture.image, texture.format, .TRANSFER_DST_OPTIMAL, target_layout) or_return

  return .Success
}

create_texture :: proc(using ctx: ^Context, tex_width: i32, tex_height: i32, tex_channels: i32,
  image_usage: ImageUsage) -> (handle: TextureResourceHandle, err: Error) {
  // Create the resource
  handle = auto_cast _create_resource(&resource_manager, .Texture) or_return
  texture: ^Texture = auto_cast _get_resource(&resource_manager, auto_cast handle) or_return
  
  // image_sampler->resource_uid = p_vkrs->resource_uid_counter++; // TODO
  texture.sampler_usage = image_usage
  texture.width = auto_cast tex_width
  texture.height = auto_cast tex_height
  texture.size = auto_cast (tex_width * tex_height * 4) // TODO
  texture.format = swap_chain.format.format
  texture.intended_usage = image_usage

  // Create the image
  image_create_info := vk.ImageCreateInfo {
    sType = .IMAGE_CREATE_INFO,
    imageType = .D2,
    extent = vk.Extent3D {
      width = auto_cast tex_width,
      height = auto_cast tex_height,
      depth = 1,
    },
    mipLevels = 1,
    arrayLayers = 1,
    format = texture.format,
    tiling = .OPTIMAL,
    initialLayout = .UNDEFINED,
    samples = {._1},
  }
  switch image_usage {
    case .ShaderReadOnly:
      image_create_info.usage = { .SAMPLED, .TRANSFER_DST }
      texture.current_layout = .UNDEFINED
    // case .ColorAttachment:
    //   image_create_info.usage = { .COLOR_ATTACHMENT }
    //   image_create_info.initialLayout = .UNDEFINED
    // case .DepthStencilAttachment:
    //   image_create_info.usage = { .DEPTH_STENCIL_ATTACHMENT }
    //   image_create_info.initialLayout = .UNDEFINED
    // case .RenderTarget:
    //   image_create_info.usage = { .COLOR_ATTACHMENT }
    //   image_create_info.initialLayout = .UNDEFINED
    // case .Present_KHR:
    //   image_create_info.usage = { .PRESENT_SRC_KHR }
    //   image_create_info.initialLayout = .UNDEFINED
  }

  // Allocate memory for the image
  alloc_create_info := vma.AllocationCreateInfo {
    usage = .AUTO_PREFER_DEVICE,
    flags = {.DEDICATED_MEMORY},
    priority = 1.0,
  }

  vkres := vma.CreateImage(ctx.vma_allocator, &image_create_info, &alloc_create_info, &texture.image, &texture.allocation, nil)
  if vkres != .SUCCESS {
    fmt.eprintln("vma.CreateImage failed:", vkres)
    err = .NotYetDetailed
    return
  }

  // Image View
  view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = texture.image,
    viewType = .D2,
    format = texture.format,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = { .COLOR },
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }

  vkres = vk.CreateImageView(ctx.device, &view_info, nil, &texture.image_view)
  if vkres != .SUCCESS {
    fmt.eprintln("vkCreateImageView failed:", vkres)
    err = .NotYetDetailed
    return
  }

  // switch (image_usage) {
  // case MVK_IMAGE_USAGE_READ_ONLY: {
  //   // printf("MVK_IMAGE_USAGE_READ_ONLY\n");
  //   image_sampler->framebuffer = NULL;
  // } break;
  // case MVK_IMAGE_USAGE_RENDER_TARGET_2D: {
  //   // printf("MVK_IMAGE_USAGE_RENDER_TARGET_2D\n");
  //   // Create Framebuffer
  //   VkImageView attachments[1] = {image_sampler->view};

  //   VkFramebufferCreateInfo framebuffer_create_info = {};
  //   framebuffer_create_info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
  //   framebuffer_create_info.pNext = NULL;
  //   framebuffer_create_info.renderPass = p_vkrs->offscreen_render_pass_2d;
  //   framebuffer_create_info.attachmentCount = 1;
  //   framebuffer_create_info.pAttachments = attachments;
  //   framebuffer_create_info.width = texWidth;
  //   framebuffer_create_info.height = texHeight;
  //   framebuffer_create_info.layers = 1;

  //   res = vkCreateFramebuffer(p_vkrs->device, &framebuffer_create_info, NULL, &image_sampler->framebuffer);
  //   VK_CHECK(res, "vkCreateFramebuffer");

  // } break;
  // }
  // switch image_usage {
  //   case .ShaderReadOnly:
  //     texture.framebuffer = auto_cast 0
  //   case .RenderTarget:
  //     fmt.eprintln("RenderTarget2D/3D not implemented")
  //     err = .NotYetImplemented
  //     return
  //   // case .RenderTarget2D:
  //   //   // Create Framebuffer
  //   //   attachments := [1]vk.ImageView { texture.sampler_usage }

  //   //   framebuffer_create_info := vk.FramebufferCreateInfo {
  //   //     sType = .FRAMEBUFFER_CREATE_INFO,
  //   //     renderPass = ctx.offscreen_render_pass_2d,
  //   //     attachmentCount = len(attachments),
  //   //     pAttachments = &attachments[0],
  //   //     width = tex_width,
  //   //     height = tex_height,
  //   //     layers = 1,
  //   //   }

  //   //   vkres = vk.CreateFramebuffer(ctx.device, &framebuffer_create_info, nil, &texture.framebuffer)
  //   //   if vkres != .SUCCESS {
  //   //     fmt.eprintln("vkCreateFramebuffer failed:", vkres)
  //   //     err = .NotYetDetailed
  //   //     return
  //   //   }
  //   //   // case MVK_IMAGE_USAGE_RENDER_TARGET_3D: {
  //   //   //   // printf("MVK_IMAGE_USAGE_RENDER_TARGET_3D\n");
  //   //   //   // Create Framebuffer
  //   //   //   VkImageView attachments[2] = {image_sampler->view, p_vkrs->depth_buffer.view};
    
  //   //   //   VkFramebufferCreateInfo framebuffer_create_info = {};
  //   //   //   framebuffer_create_info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
  //   //   //   framebuffer_create_info.pNext = NULL;
  //   //   //   framebuffer_create_info.renderPass = p_vkrs->offscreen_render_pass_3d;
  //   //   //   framebuffer_create_info.attachmentCount = 2;
  //   //   //   framebuffer_create_info.pAttachments = attachments;
  //   //   //   framebuffer_create_info.width = texWidth;
  //   //   //   framebuffer_create_info.height = texHeight;
  //   //   //   framebuffer_create_info.layers = 1;
    
  //   //   //   res = vkCreateFramebuffer(p_vkrs->device, &framebuffer_create_info, NULL, &image_sampler->framebuffer);
  //   //   //   VK_CHECK(res, "vkCreateFramebuffer");
  //   //   // } break;
  //   // case .RenderTarget3D:
  //   //   // Create Framebuffer
  //   //   attachments := [2]vk.ImageView { texture.sampler_usage, ctx.depth_buffer.view }

  //   //   framebuffer_create_info = vk.FramebufferCreateInfo {
  //   //     sType = .FRAMEBUFFER_CREATE_INFO,
  //   //     renderPass = ctx.offscreen_render_pass_3d,
  //   //     attachmentCount = len(attachments),
  //   //     pAttachments = &attachments[0],
  //   //     width = tex_width,
  //   //     height = tex_height,
  //   //     layers = 1,
  //   //   }

  //   //   vkres = vk.CreateFramebuffer(ctx.device, &framebuffer_create_info, nil, &texture.framebuffer)
  //   //   if vkres != .SUCCESS {
  //   //     fmt.eprintln("vkCreateFramebuffer failed:", vkres)
  //   //     err = .NotYetDetailed
  //   //     return
  //   //   }
  // }


  // // Sampler
  // VkSamplerCreateInfo samplerInfo = {};
  // samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
  // samplerInfo.magFilter = VK_FILTER_LINEAR;
  // samplerInfo.minFilter = VK_FILTER_LINEAR;
  // samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
  // samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
  // samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
  // samplerInfo.anisotropyEnable = VK_TRUE;
  // samplerInfo.maxAnisotropy = 16.0f;
  // samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
  // samplerInfo.unnormalizedCoordinates = VK_FALSE;
  // samplerInfo.compareEnable = VK_FALSE;
  // samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
  // samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;

  // res = vkCreateSampler(p_vkrs->device, &samplerInfo, NULL, &image_sampler->sampler);
  // VK_CHECK(res, "vkCreateSampler");

  // *out_image = image_sampler;

  // Sampler
  sampler_info := vk.SamplerCreateInfo {
    sType = .SAMPLER_CREATE_INFO,
    magFilter = .LINEAR,
    minFilter = .LINEAR,
    addressModeU = .REPEAT,
    addressModeV = .REPEAT,
    addressModeW = .REPEAT,
    anisotropyEnable = false,
    // maxAnisotropy = 16.0,
    borderColor = .INT_OPAQUE_BLACK,
    unnormalizedCoordinates = false,
    compareEnable = false,
    compareOp = .ALWAYS,
    mipmapMode = .LINEAR,
  }
  vkres = vk.CreateSampler(ctx.device, &sampler_info, nil, &texture.sampler)
  if vkres != .SUCCESS {
    fmt.eprintln("vkCreateSampler failed:", vkres)
    err = .NotYetDetailed
    return
  }

  return
}

// TODO -- PR STBI?
STBI_default :: 0 // only used for desired_channels
STBI_grey :: 1
STBI_grey_alpha :: 2
STBI_rgb :: 3
STBI_rgb_alpha :: 4

/* Loads a texture from a file for use as an image sampler in a shader.
 * The texture is loaded into a staging buffer, then copied to a device local
 * buffer. The staging buffer is then freed.
 * @param ctx The Violin Context
 * @param filepath The path to the file to load
 */
load_texture_from_file :: proc(using ctx: ^Context, filepath: cstring) -> (rh: TextureResourceHandle, err: Error) {
  
  tex_width, tex_height, tex_channels: libc.int
  pixels := stbi.load(filepath, &tex_width, &tex_height, &tex_channels, STBI_rgb_alpha)
  defer stbi.image_free(pixels)
  if pixels == nil {
    err = .NotYetDetailed
    fmt.eprintln("Violin.load_texture_from_file: Failed to load image from file:", filepath)
    return
  }
  
  image_size: int = auto_cast (tex_width * tex_height * STBI_rgb_alpha)
  fmt.println(pixels)
  // fmt.println("width:", tex_width, "height:", tex_height, "channels:", tex_channels, "image_size:", image_size)

  rh = create_texture(ctx, tex_width, tex_height, tex_channels, .ShaderReadOnly) or_return
  texture: ^Texture = auto_cast _get_resource(&resource_manager, auto_cast rh) or_return

  write_to_texture(ctx, rh, pixels, image_size) or_return

  fmt.printf("loaded %s> width:%i height:%i channels:%i\n", filepath, tex_width, tex_height, tex_channels);

  return
}

create_uniform_buffer :: proc(using ctx: ^Context, size_in_bytes: vk.DeviceSize, intended_usage: BufferUsage) -> (rh: ResourceHandle,
  err: Error) {
  #partial switch intended_usage {
    case .Dynamic:
      // Create the Buffer
      buffer_create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size = size_in_bytes,
        usage = {.UNIFORM_BUFFER, .TRANSFER_DST},
      }

      allocation_create_info := vma.AllocationCreateInfo {
        usage = .AUTO,
        flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD, .MAPPED},
      }
      
      rh = _create_resource(&ctx.resource_manager, .Buffer) or_return
      buffer: ^Buffer = auto_cast get_resource(&ctx.resource_manager, rh) or_return
      buffer.size = size_in_bytes
      vkres := vma.CreateBuffer(vma_allocator, &buffer_create_info, &allocation_create_info, &buffer.buffer,
        &buffer.allocation, &buffer.allocation_info)
      if vkres != .SUCCESS {
        fmt.eprintln("create_uniform_buffer>vmaCreateBuffer failed:", vkres)
        err = .NotYetDetailed
      }
    case:
      fmt.println("create_uniform_buffer() > Unsupported buffer usage:", intended_usage)
      err = .NotYetDetailed
  }

  return
}

// TODO -- allow/disable staging - test performance
// TODO -- single-use-commands within processing of render command buffers. whats the deal
write_to_buffer :: proc(using ctx: ^Context, rh: ResourceHandle, data: rawptr, size_in_bytes: int) -> Error {
  buffer: ^Buffer = auto_cast get_resource(&resource_manager, rh) or_return

  // Get the created buffers memory properties
  mem_property_flags: vk.MemoryPropertyFlags
  vma.GetAllocationMemoryProperties(vma_allocator, buffer.allocation, &mem_property_flags)
  
  if vk.MemoryPropertyFlag.HOST_VISIBLE in mem_property_flags {
    // Allocation ended up in a mappable memory and is already mapped - write to it directly.

    // [Executed in runtime]:
    mem.copy(buffer.allocation_info.pMappedData, data, size_in_bytes)
  } else {
    // Create a staging buffer
    staging_buffer_create_info := vk.BufferCreateInfo {
      sType = .BUFFER_CREATE_INFO,
      size = auto_cast size_in_bytes,
      usage = {.TRANSFER_SRC},
    }

    staging_allocation_create_info := vma.AllocationCreateInfo {
      usage = .AUTO,
      flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
    }
    
    staging: Buffer
    vkres := vma.CreateBuffer(vma_allocator, &staging_buffer_create_info, &staging_allocation_create_info, &staging.buffer,
      &staging.allocation, &staging.allocation_info)
    if vkres != .SUCCESS {
      fmt.eprintln("write_to_buffer>vmaCreateBuffer failed:", vkres)
      return .NotYetDetailed
    }
    defer vma.DestroyBuffer(vma_allocator, staging.buffer, staging.allocation)

    // Copy data to the staging buffer
    mem.copy(staging.allocation_info.pMappedData, data, size_in_bytes)

    // Copy buffers
    _begin_single_time_commands(ctx) or_return

    copy_region := vk.BufferCopy {
      srcOffset = 0,
      dstOffset = 0,
      size = auto_cast size_in_bytes,
    }
    vk.CmdCopyBuffer(ctx.st_command_buffer, staging.buffer, buffer.buffer, 1, &copy_region)

    _end_single_time_commands(ctx) or_return
  }

  return .Success
}

create_vertex_buffer :: proc(using ctx: ^Context, vertex_data: rawptr, vertex_size_in_bytes: int,
  vertex_count: int) -> (rh: VertexBufferResourceHandle, err: Error) {
  // Create the resource
  rh = auto_cast _create_resource(&ctx.resource_manager, .VertexBuffer) or_return
  vertex_buffer: ^VertexBuffer = auto_cast _get_resource(&ctx.resource_manager, auto_cast rh) or_return

  // Set
  vertex_buffer.vertex_count = vertex_count
  vertex_buffer.size = auto_cast (vertex_size_in_bytes * vertex_count)

  // Staging buffer
  staging: Buffer
  buffer_info := vk.BufferCreateInfo{
    sType = .BUFFER_CREATE_INFO,
    size  = cast(vk.DeviceSize)(vertex_size_in_bytes * vertex_count),
    usage = {.TRANSFER_SRC},
    sharingMode = .EXCLUSIVE,
  }
  allocation_create_info := vma.AllocationCreateInfo {
    usage = .AUTO,
    flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
  }

  vkres := vma.CreateBuffer(vma_allocator, &buffer_info, &allocation_create_info, &staging.buffer,
    &staging.allocation, &staging.allocation_info)
  if vkres != .SUCCESS {
    fmt.eprintf("Error: Failed to create staging buffer!\n");
    destroy_resource_any(ctx, auto_cast rh)
    err = .NotYetDetailed
    return
  }
  defer vma.DestroyBuffer(vma_allocator, staging.buffer, staging.allocation) //TODO -- one day, why isn't this working?

  // Copy data to the staging buffer
  mem.copy(staging.allocation_info.pMappedData, vertex_data, cast(int)vertex_buffer.size)

  // Create the vertex buffer
  buffer_info.usage = {.TRANSFER_DST, .VERTEX_BUFFER}
  allocation_create_info.flags = {}
  vkres = vma.CreateBuffer(vma_allocator, &buffer_info, &allocation_create_info, &vertex_buffer.buffer,
    &vertex_buffer.allocation, &vertex_buffer.allocation_info)
  if vkres != .SUCCESS {
    fmt.eprintf("Error: Failed to create vertex buffer!\n");
    destroy_resource_any(ctx, auto_cast rh)
    err = .NotYetDetailed
    return
  }

  // Queue Commands to copy the staging buffer to the vertex buffer
  _begin_single_time_commands(ctx) or_return

  copy_region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = 0,
    size = vertex_buffer.size,
  }
  vk.CmdCopyBuffer(ctx.st_command_buffer, staging.buffer, vertex_buffer.buffer, 1, &copy_region)

  _end_single_time_commands(ctx) or_return

  return
}

create_index_buffer :: proc(using ctx: ^Context, indices: ^u16, index_count: int) -> (rh:IndexBufferResourceHandle, err: Error) {
  // Create the resource
  rh = auto_cast _create_resource(&ctx.resource_manager, .IndexBuffer) or_return
  index_buffer: ^IndexBuffer = auto_cast _get_resource(&ctx.resource_manager, auto_cast rh) or_return

  // Set
  index_buffer.index_count = index_count
  index_size: int
  index_buffer.index_type = .UINT16 // TODO -- support 32 bit indices
  #partial switch index_buffer.index_type {
    case .UINT16:
      index_size = 2
    case .UINT32:
      index_size = 4
    case:
      fmt.eprintln("create_index_buffer>Unsupported index type")
      destroy_resource_any(ctx, auto_cast rh)
      err = .NotYetDetailed
      return
  }
  index_buffer.size = auto_cast (index_size * index_count)
  
  // Staging buffer
  staging: Buffer
  buffer_create_info := vk.BufferCreateInfo{
    sType = .BUFFER_CREATE_INFO,
    size  = index_buffer.size,
    usage = {.TRANSFER_SRC},
    sharingMode = .EXCLUSIVE,
  };
  allocation_create_info := vma.AllocationCreateInfo {
    usage = .AUTO,
    flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
  }

  vkres := vma.CreateBuffer(vma_allocator, &buffer_create_info, &allocation_create_info, &staging.buffer,
    &staging.allocation, &staging.allocation_info)
  if vkres != .SUCCESS {
    fmt.eprintf("Error: Failed to create staging buffer!\n");
    err = .NotYetDetailed
    return
  }
  // defer vk.DestroyBuffer(device, staging.buffer, nil)
  // defer vk.FreeMemory(device, staging.allocation_info.deviceMemory, nil)
  defer vma.DestroyBuffer(vma_allocator, staging.buffer, staging.allocation) 

  // Copy from staging buffer to index buffer
  mem.copy(staging.allocation_info.pMappedData, indices, auto_cast index_buffer.size)

  buffer_create_info.usage = {.TRANSFER_DST, .INDEX_BUFFER}
  allocation_create_info.flags = {}
  vkres = vma.CreateBuffer(vma_allocator, &buffer_create_info, &allocation_create_info, &index_buffer.buffer,
    &index_buffer.allocation, &index_buffer.allocation_info)
  if vkres != .SUCCESS {
    fmt.eprintf("Error: Failed to create index buffer!\n");
    err = .NotYetDetailed
    return
  }

  // Copy buffers
  _begin_single_time_commands(ctx) or_return

  copy_region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = 0,
    size = index_buffer.size,
  }
  vk.CmdCopyBuffer(ctx.st_command_buffer, staging.buffer, index_buffer.buffer, 1, &copy_region)

  _end_single_time_commands(ctx) or_return

  return
}

// create_index_buffer :: proc(using ctx: ^Context, render_data: ^RenderData, indices: ^u16, index_count: int) -> Error {
//   render_data.index_buffer.length = index_count;
//   render_data.index_buffer.size = cast(vk.DeviceSize)(index_count * size_of(u16));
  
//   staging: Buffer;
//   create_buffer(ctx, size_of(u16), index_count, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging);
  
//   data: rawptr;
//   vk.MapMemory(device, staging.ttmemory, 0, render_data.index_buffer.size, {}, &data);
//   mem.copy(data, indices, cast(int)render_data.index_buffer.size);
//   vk.UnmapMemory(device, staging.ttmemory);
  
//   create_buffer(ctx, size_of(u16), index_count, {.INDEX_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL}, &render_data.index_buffer);
//   copy_buffer(ctx, staging, render_data.index_buffer, render_data.index_buffer.size);
  
//   vk.FreeMemory(device, staging.ttmemory, nil);
//   vk.DestroyBuffer(device, staging.buffer, nil);

//   return .Success
// }

// create_buffer :: proc(using ctx: ^Context, member_size: int, count: int, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: ^Buffer) {

//   buffer_info := vk.BufferCreateInfo{
//     sType = .BUFFER_CREATE_INFO,
//     size  = cast(vk.DeviceSize)(member_size * count),
//     usage = usage,
//     sharingMode = .EXCLUSIVE,
//   };
  
//   if res := vk.CreateBuffer(device, &buffer_info, nil, &buffer.buffer); res != .SUCCESS
//   {
//     fmt.eprintf("Error: failed to create buffer\n");
//     os.exit(1);
//   }
  
//   mem_requirements: vk.MemoryRequirements;
//   vk.GetBufferMemoryRequirements(device, buffer.buffer, &mem_requirements);
  
//   alloc_info := vk.MemoryAllocateInfo {
//     sType = .MEMORY_ALLOCATE_INFO,
//     allocationSize = mem_requirements.size,
//     memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
//   }
  
//   if res := vk.AllocateMemory(device, &alloc_info, nil, &buffer.ttmemory); res != .SUCCESS {
//     fmt.eprintf("Error: Failed to allocate buffer memory!\n");
//     os.exit(1);
//   }
  
//   vk.BindBufferMemory(device, buffer.buffer, buffer.ttmemory, 0);
// }
create_render_program :: proc(ctx: ^Context, info: ^RenderProgramCreateInfo) -> (rp: RenderProgram, err: Error) {
  MAX_INPUT :: 16
  err = .Success

  vertex_binding := vk.VertexInputBindingDescription {
    binding = 0,
    stride = auto_cast info.vertex_size,
    inputRate = .VERTEX,
  }

  vertex_attributes_count := len(info.input_attributes)
  layout_bindings_count := len(info.buffer_bindings)
  if vertex_attributes_count > MAX_INPUT || layout_bindings_count > MAX_INPUT {
    err = .NotYetDetailed
    return
  }

  vertex_attributes : [MAX_INPUT]vk.VertexInputAttributeDescription
  for i in 0..<len(info.input_attributes) {
    vertex_attributes[i] = vk.VertexInputAttributeDescription {
      binding = 0,
      location = info.input_attributes[i].location,
      format = info.input_attributes[i].format,
      offset = info.input_attributes[i].offset,
    }
  }

  // Descriptors
  rp.layout_bindings = make_slice([]vk.DescriptorSetLayoutBinding, layout_bindings_count)
  for i in 0..<layout_bindings_count do rp.layout_bindings[i] = info.buffer_bindings[i]

  // Next take layout bindings and use them to create a descriptor set layout
  layout_create_info := vk.DescriptorSetLayoutCreateInfo {
    sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = auto_cast len(rp.layout_bindings),
    pBindings = &rp.layout_bindings[0],
  }

  // TODO -- may cause segmentation fault? check-it
  res := vk.CreateDescriptorSetLayout(ctx.device, &layout_create_info, nil, &rp.descriptor_layout);
  if res != .SUCCESS {
    fmt.println("Failed to create descriptor set layout")
  }

  // Pipeline
  rp.pipeline = create_graphics_pipeline(ctx, &info.pipeline_config, &vertex_binding, vertex_attributes[:vertex_attributes_count],
    &rp.descriptor_layout) or_return

  // fmt.println("create_render_program return")
  return
}

// FontResourceHandle
// 
// VkResult mvk_load_font(vk_render_state *p_vkrs, const char *const filepath, float font_height,
//   mcr_font_resource **p_resource)
// {
// VkResult res;

load_font :: proc(using ctx: ^Context, ttf_filepath: string, font_height: f32) -> (fh: FontResourceHandle, err: Error) {
// // Font is a common resource -- check font cache for existing -- TODO?
// char *font_name;
// {
// int index_of_last_slash = -1;
// for (int i = 0;; i++) {
// if (filepath[i] == '\0') {
// printf("INVALID FORMAT filepath='%s'\n", filepath);
// return VK_ERROR_UNKNOWN;
// }
// if (filepath[i] == '.') {
// int si = index_of_last_slash >= 0 ? (index_of_last_slash + 1) : 0;
// font_name = (char *)malloc(sizeof(char) * (i - si + 1));
// strncpy(font_name, filepath + si, i - si);
// font_name[i - si] = '\0';
// break;
// }
// else if (filepath[i] == '\\' || filepath[i] == '/') {
// index_of_last_slash = i;
// }
// }

// for (int i = 0; i < p_vkrs->loaded_fonts.count; ++i) {
// if (p_vkrs->loaded_fonts.fonts[i]->height == font_height &&
// !strcmp(p_vkrs->loaded_fonts.fonts[i]->name, font_name)) {
// *p_resource = p_vkrs->loaded_fonts.fonts[i];

// printf("using cached font texture> name:%s height:%.2f resource_uid:%u\n", font_name, font_height,
// (*p_resource)->texture->resource_uid);
// free(font_name);

// return VK_SUCCESS;
// }
// }
// }

// Load font
// stbi_uc ttf_buffer[1 << 20];
// fread(ttf_buffer, 1, 1 << 20, fopen(filepath, "rb"));
  // ttf_buffer[]
  file, oerr := os.open(ttf_filepath)


  errno: os.Errno
  h_ttf: os.Handle

  // Open the source file
  h_ttf, errno = os.open(ttf_filepath)
  if errno != os.ERROR_NONE {
    fmt.printf("Error File I/O: couldn't open font path='%s' set full path accordingly\n", ttf_filepath)
    err = .NotYetDetailed
    return
  }
  defer os.close(h_ttf)

  // read_success: bool
  ttf_buffer, read_success := os.read_entire_file_from_handle(h_ttf)
  if !read_success {
    fmt.println("Could not read full ttf font file:", ttf_filepath)
    err = .NotYetDetailed
    return
  }
  defer delete(ttf_buffer)

  // Create the resource
  fh = auto_cast _create_resource(&resource_manager, .Font) or_return
  font: ^Font = auto_cast _get_resource(&resource_manager, auto_cast fh) or_return
  font.texture = create_texture(ctx, tex_width, tex_height, tex_channels, .ShaderReadOnly) or_return
  font.char_data = auto_cast mem.alloc(size=96 * size_of(stbtt.bakedchar), allocator = context.temp_allocator)

// const int texWidth = 256, texHeight = 256, texChannels = 4;
// stbi_uc temp_bitmap[texWidth * texHeight];
// stbtt_bakedchar *cdata = (stbtt_bakedchar *)malloc(sizeof(stbtt_bakedchar) * 96); // ASCII 32..126 is 95 glyphs
// stbtt_BakeFontBitmap(ttf_buffer, 0, font_height, temp_bitmap, texWidth, texHeight, 32, 96,
//   cdata); // no guarantee this fits!
  tex_width :: 256
  tex_height :: 256
  tex_channels :: 4
  temp_bitmap: [^]u8 = auto_cast mem.alloc(size=tex_width * tex_height, allocator = context.temp_allocator)
  // defer free(temp_bitmap) // TODO -- no clue why this is causing segmentation fault. I've gotta be missing something right?

  stb_res := stbtt.BakeFontBitmap(&ttf_buffer[0], 0, font_height, temp_bitmap, tex_width, tex_height, 32, 96, font.char_data)
  if stb_res < 1 {
    fmt.println("ERROR Failed to bake font bitmap:", stb_res)
    err = .NotYetDetailed
    return
  }
  // stbtt.FreeBitmap(temp_bitmap, nil)

// // // printf("garbagein: font_height:%f\n", font_height);
// // stbi_uc pixels[texWidth * texHeight * 4];
// // {
// // int p = 0;
// // for (int i = 0; i < texWidth * texHeight; ++i) {
// // pixels[p++] = temp_bitmap[i];
// // pixels[p++] = temp_bitmap[i];
// // pixels[p++] = temp_bitmap[i];
// // pixels[p++] = 255;
// // }
// // }

  // Copy the font data into the texture
  pixels := make([^]u8, tex_width * tex_height * 4, context.temp_allocator)
  defer free(pixels)
  {
    p := 0
    for i := 0; i < tex_width * tex_height; i += 1 {
      pixels[p] = temp_bitmap[i]
      pixels[p + 1] = temp_bitmap[i]
      pixels[p + 2] = temp_bitmap[i]
      pixels[p + 3] = 255
      p += 4
    }
  }
  write_to_texture(ctx, font.texture, pixels, tex_width * tex_height * 4) or_return

  // 



// mcr_texture_image *texture;
// res = mvk_load_image_sampler(p_vkrs, texWidth, texHeight, texChannels, MVK_IMAGE_USAGE_READ_ONLY, pixels, &texture);
// VK_CHECK(res, "mvk_load_image_sampler");
  // rh := _create_resource(&ctx.resource_manager, .Texture, )

// append_to_collection((void ***)&p_vkrs->textures.items, &p_vkrs->textures.alloc, &p_vkrs->textures.count, texture);

// // Font is a common resource -- cache so multiple loads reference the same resource uid
// {
// mcr_font_resource *font = (mcr_font_resource *)malloc(sizeof(mcr_font_resource));
// append_to_collection((void ***)&p_vkrs->loaded_fonts.fonts, &p_vkrs->loaded_fonts.capacity,
//     &p_vkrs->loaded_fonts.count, font);

// font->name = font_name;
// font->height = font_height;
// font->texture = texture;
// font->char_data = cdata;
// {
// float lowest = 500;
// for (int ci = 0; ci < 96; ++ci) {
// stbtt_aligned_quad q;

// // printf("garbagein: %i %i %f %f %i\n", (int)font_image->width, (int)font_image->height, align_x, align_y,
// // letter
// // - 32);
// float ax = 100, ay = 300;
// stbtt_GetBakedQuad(cdata, (int)texWidth, (int)texHeight, ci, &ax, &ay, &q, 1);
// if (q.y0 < lowest)
// lowest = q.y0;
// // printf("baked_quad: s0=%.2f s1==%.2f t0=%.2f t1=%.2f x0=%.2f x1=%.2f y0=%.2f y1=%.2f lowest=%.3f\n", q.s0,
// // q.s1,
// //        q.t0, q.t1, q.x0, q.x1, q.y0, q.y1, lowest);
// }
// font->draw_vertical_offset = 300 - lowest;
// }

// *p_resource = font;
// printf("generated font resource> name:%s height:%.2f resource_uid:%u\n", font_name, font_height,
// font->texture->resource_uid);
// }

// return res;
  // fmt.println("load_font> NotYetImplemented")
  // err = .NotYetImplemented
  return
}
