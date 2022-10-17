package violin

import "core:os"
import "core:fmt"
import "core:c/libc"
import "core:mem"
import "core:sync"

import vk "vendor:vulkan"
// import stb "vendor:stb/lib"
import stbi "vendor:stb/image"
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
VertexBufferResourceHandle :: distinct ResourceHandle
IndexBufferResourceHandle :: distinct ResourceHandle
RenderPassResourceHandle :: distinct ResourceHandle
TwoDRenderResourceHandle :: distinct ResourceHandle

ResourceKind :: enum {
  Buffer = 1,
  Texture,
  DepthBuffer,
  RenderPass,
  TwoDRenderResource,
  VertexBuffer,
  IndexBuffer,
}

Resource :: struct {
  kind: ResourceKind,
  data: union { Buffer, Texture, DepthBuffer, RenderPass, TwoDRenderResource, VertexBuffer, IndexBuffer },
}

ImageSamplerUsage :: enum {
  ReadOnly = 1,
  RenderTarget,
}

Buffer :: struct {
  buffer: vk.Buffer,
  allocation: vma.Allocation,
  allocation_info: vma.AllocationInfo,
  size:   vk.DeviceSize,
}

Texture :: struct {
  sampler_usage: ImageSamplerUsage,
  width: u32,
  height: u32,
  size: u32,
  format: vk.Format,
  image: vk.Image,
  image_memory: vk.DeviceMemory,
  image_view: vk.ImageView,
  framebuffer: vk.Framebuffer,
  sampler: vk.Sampler,
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

TwoDRenderResource :: struct {
  render_pass: RenderPassResourceHandle,
  colored_rect_render_program: RenderProgram,
  rect_vertex_buffer: VertexBufferResourceHandle,
  rect_index_buffer: IndexBufferResourceHandle,
  colored_rect_uniform_buffer: ResourceHandle,
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

_create_resource :: proc(using rm: ^ResourceManager, resource_kind: ResourceKind, size: u32 = 0) -> (rh: ResourceHandle, err: Error) {
  sync.lock(&rm._mutex)
  defer sync.unlock(&rm._mutex)

  switch resource_kind {
    case .Texture, .Buffer, .DepthBuffer, .RenderPass, .TwoDRenderResource, .VertexBuffer, .IndexBuffer:
      rh = resource_index
      resource_index += 1
      res : ^Resource = auto_cast mem.alloc(size_of(Resource))
      resource_map[rh] = res
      res.kind = resource_kind
      fmt.println("Created resource: ", rh)
      return
    case:
      fmt.println("Resource type not supported:", resource_kind)
      err = .NotYetDetailed
      return
  }
}

get_resource_any :: proc(using rm: ^ResourceManager, rh: ResourceHandle) -> (ptr: rawptr, err: Error) {
  res := resource_map[rh]
  if res == nil {
    err = .ResourceNotFound
    return
  }

  ptr = &res.data
  return
}

get_resource_render_pass :: proc(using rm: ^ResourceManager, rh: RenderPassResourceHandle) -> (ptr: ^RenderPass, err: Error) {
  ptr = auto_cast get_resource_any(rm, auto_cast rh) or_return
  return
}

get_resource :: proc {get_resource_any, get_resource_render_pass}

destroy_resource_any :: proc(using ctx: ^Context, rh: ResourceHandle) -> Error {
  res := resource_manager.resource_map[rh]
  if res == nil {
    fmt.println("Resource not found:", rh)
    return .ResourceNotFound
  }
  // fmt.println("Destroying resource:", rh, "of type:", res.kind)

  switch res.kind {
    case .Texture:
      texture : ^Texture = auto_cast &res.data
      vk.DestroyImage(ctx.device, texture.image, nil)
      vk.FreeMemory(ctx.device, texture.image_memory, nil)
      vk.DestroyImageView(ctx.device, texture.image_view, nil)
      vk.DestroySampler(ctx.device, texture.sampler, nil)
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
    case .TwoDRenderResource:
      ui: ^TwoDRenderResource = auto_cast &res.data
      
      destroy_resource(ctx, ui.render_pass)
      destroy_render_program(ctx, &ui.colored_rect_render_program)
    case .VertexBuffer, .IndexBuffer:
      vb: ^VertexBuffer = auto_cast &res.data
      
      vma.DestroyBuffer(vma_allocator, vb.buffer, vb.allocation)
    case:
      fmt.println("Resource type not supported:", res.kind)
      return .NotYetDetailed
  }

  delete_key(&resource_manager.resource_map, rh)
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

destroy_ui_render_resource :: proc(using ctx: ^Context, rh: TwoDRenderResourceHandle) -> Error {
  return destroy_resource_any(ctx, auto_cast rh)
}

destroy_resource :: proc {destroy_resource_any, destroy_render_pass, destroy_ui_render_resource}


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
    destination_stage = { .FRAGMENT_SHADER }
  } else {
    fmt.eprintln("unsupported layout transition")
    return .NotYetDetailed
  }
  
  vk.CmdPipelineBarrier(ctx.st_command_buffer, source_stage, destination_stage, {}, 0, nil, 0, nil, 1, &barrier)
  
  _end_single_time_commands(ctx) or_return

  return .Success
}

copy_buffer_to_image :: proc(ctx: ^Context, buffer: vk.Buffer, image: vk.Image, width: u32, height: u32) -> Error {
  
  _begin_single_time_commands(ctx) or_return
  
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
      width = width,
      height = height,
      depth = 1,
    },
  }

  vk.CmdCopyBufferToImage(ctx.st_command_buffer, buffer, image, .TRANSFER_DST_OPTIMAL, 1, &region)

  _end_single_time_commands(ctx) or_return

  return .Success
}

load_image_sampler :: proc(ctx: ^Context, tex_width: i32, tex_height: i32, tex_channels: i32, image_usage: ImageSamplerUsage,
  pixels: [^]u8) -> (handle: ResourceHandle, err: Error) {

  handle = auto_cast _create_resource(&ctx.resource_manager, .Texture) or_return
  texture : ^Texture = auto_cast get_resource(&ctx.resource_manager, handle) or_return
  
  // image_sampler->resource_uid = p_vkrs->resource_uid_counter++; // TODO
  texture.sampler_usage = image_usage
  texture.width = auto_cast tex_width
  texture.height = auto_cast tex_height
  texture.size = auto_cast (tex_width * tex_height * 4) // TODO

  // Copy to buffer
  staging_buffer: vk.Buffer
  staging_buffer_memory: vk.DeviceMemory

  // VkBufferCreateInfo bufferInfo = {};
  // bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  // bufferInfo.size = image_sampler->size;
  // bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
  // bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  buffer_info := vk.BufferCreateInfo{
    sType = .BUFFER_CREATE_INFO,
    size = auto_cast texture.size,
    usage = { .TRANSFER_SRC },
    sharingMode = .EXCLUSIVE,
  }

  // res = vkCreateBuffer(p_vkrs->device, &bufferInfo, NULL, &stagingBuffer);
  // VK_CHECK(res, "vkCreateBuffer");
  vkres := vk.CreateBuffer(ctx.device, &buffer_info, nil, &staging_buffer)
  if vkres != .SUCCESS {
    fmt.eprintln("vkCreateBuffer failed:", vkres)
    err = .NotYetDetailed
    return
  }

  mem_requirements: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(ctx.device, staging_buffer, &mem_requirements)

  // VkMemoryAllocateInfo allocInfo = {};
  // allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  // allocInfo.allocationSize = memRequirements.size;
  // bool pass = mvk_get_properties_memory_type_index(
  //     p_vkrs, memRequirements.memoryTypeBits,
  //     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &allocInfo.memoryTypeIndex);
  // MCassert(pass, "No mappable, coherent memory");
  alloc_info := vk.MemoryAllocateInfo{
    sType = .MEMORY_ALLOCATE_INFO,
    allocationSize = mem_requirements.size,
  }
  alloc_info.memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, { .HOST_VISIBLE, .HOST_COHERENT })

  vkres = vk.AllocateMemory(ctx.device, &alloc_info, nil, &staging_buffer_memory)
  if vkres != .SUCCESS {
    fmt.eprintln("vkAllocateMemory failed:", vkres)
    err = .NotYetDetailed
    return
  }

  vkres = vk.BindBufferMemory(ctx.device, staging_buffer, staging_buffer_memory, 0)
  if vkres != .SUCCESS {
    fmt.eprintln("vkBindBufferMemory failed:", vkres)
    err = .NotYetDetailed
    return
  }

  data: rawptr
  vkres = vk.MapMemory(ctx.device, staging_buffer_memory, 0, mem_requirements.size, nil, &data)
  if vkres != .SUCCESS {
    fmt.eprintln("vkMapMemory failed:", vkres)
    err = .NotYetDetailed
    return
  }
  mem.copy(data, pixels, auto_cast texture.size)
  vk.UnmapMemory(ctx.device, staging_buffer_memory)

  // Create Image
  vk_image_usage_flags: vk.ImageUsageFlags
  switch image_usage {
    case .ReadOnly:
      vk_image_usage_flags = nil
      texture.format = ctx.swap_chain.format.format // TODO ?? Not sure what this should be
    case .RenderTarget:
      fmt.println("TODO: RenderTarget")
      err = .NotYetImplemented
      return
      // vk_image_usage_flags = { .COLOR_ATTACHMENT }
      // texture.format = ctx.swap_chain.format.format
  }

  image_info := vk.ImageCreateInfo {
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
    usage = vk_image_usage_flags | { .TRANSFER_DST, .SAMPLED },
    sharingMode = .EXCLUSIVE,
    samples = { ._1 },
    flags = nil,
  }

  vkres = vk.CreateImage(ctx.device, &image_info, nil, &texture.image)
  if vkres != .SUCCESS {
    fmt.eprintln("vkCreateImage failed:", vkres)
    err = .NotYetDetailed
    return
  }
  
  // Memory
  vk.GetImageMemoryRequirements(ctx.device, texture.image, &mem_requirements)
  alloc_info = vk.MemoryAllocateInfo{
    sType = .MEMORY_ALLOCATE_INFO,
    allocationSize = mem_requirements.size,
  }
  alloc_info.memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, { .DEVICE_LOCAL })

  vkres = vk.AllocateMemory(ctx.device, &alloc_info, nil, &texture.image_memory)
  if vkres != .SUCCESS {
    fmt.eprintln("vkAllocateMemory failed:", vkres)
    err = .NotYetDetailed
    return
  }
  
  vkres = vk.BindImageMemory(ctx.device, texture.image, texture.image_memory, 0)
  if vkres != .SUCCESS {
    fmt.eprintln("vkBindImageMemory failed:", vkres)
    err = .NotYetDetailed
    return
  }

  // Transition Image Layout
  transition_image_layout(ctx, texture.image, texture.format, .UNDEFINED, .TRANSFER_DST_OPTIMAL) or_return
  
  // Copy Buffer to Image
  copy_buffer_to_image(ctx, staging_buffer, texture.image, auto_cast tex_width, auto_cast tex_height) or_return
  
  // Transition Image Layout (again)
  transition_image_layout(ctx, texture.image, texture.format, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL) or_return
  
  // Destroy staging resources
  vk.DestroyBuffer(ctx.device, staging_buffer, nil)
  vk.FreeMemory(ctx.device, staging_buffer_memory, nil)

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
  switch image_usage {
    case .ReadOnly:
      texture.framebuffer = auto_cast 0
    case .RenderTarget:
      fmt.eprintln("RenderTarget2D/3D not implemented")
      err = .NotYetImplemented
      return
    // case .RenderTarget2D:
    //   // Create Framebuffer
    //   attachments := [1]vk.ImageView { texture.sampler_usage }

    //   framebuffer_create_info := vk.FramebufferCreateInfo {
    //     sType = .FRAMEBUFFER_CREATE_INFO,
    //     renderPass = ctx.offscreen_render_pass_2d,
    //     attachmentCount = len(attachments),
    //     pAttachments = &attachments[0],
    //     width = tex_width,
    //     height = tex_height,
    //     layers = 1,
    //   }

    //   vkres = vk.CreateFramebuffer(ctx.device, &framebuffer_create_info, nil, &texture.framebuffer)
    //   if vkres != .SUCCESS {
    //     fmt.eprintln("vkCreateFramebuffer failed:", vkres)
    //     err = .NotYetDetailed
    //     return
    //   }
    //   // case MVK_IMAGE_USAGE_RENDER_TARGET_3D: {
    //   //   // printf("MVK_IMAGE_USAGE_RENDER_TARGET_3D\n");
    //   //   // Create Framebuffer
    //   //   VkImageView attachments[2] = {image_sampler->view, p_vkrs->depth_buffer.view};
    
    //   //   VkFramebufferCreateInfo framebuffer_create_info = {};
    //   //   framebuffer_create_info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    //   //   framebuffer_create_info.pNext = NULL;
    //   //   framebuffer_create_info.renderPass = p_vkrs->offscreen_render_pass_3d;
    //   //   framebuffer_create_info.attachmentCount = 2;
    //   //   framebuffer_create_info.pAttachments = attachments;
    //   //   framebuffer_create_info.width = texWidth;
    //   //   framebuffer_create_info.height = texHeight;
    //   //   framebuffer_create_info.layers = 1;
    
    //   //   res = vkCreateFramebuffer(p_vkrs->device, &framebuffer_create_info, NULL, &image_sampler->framebuffer);
    //   //   VK_CHECK(res, "vkCreateFramebuffer");
    //   // } break;
    // case .RenderTarget3D:
    //   // Create Framebuffer
    //   attachments := [2]vk.ImageView { texture.sampler_usage, ctx.depth_buffer.view }

    //   framebuffer_create_info = vk.FramebufferCreateInfo {
    //     sType = .FRAMEBUFFER_CREATE_INFO,
    //     renderPass = ctx.offscreen_render_pass_3d,
    //     attachmentCount = len(attachments),
    //     pAttachments = &attachments[0],
    //     width = tex_width,
    //     height = tex_height,
    //     layers = 1,
    //   }

    //   vkres = vk.CreateFramebuffer(ctx.device, &framebuffer_create_info, nil, &texture.framebuffer)
    //   if vkres != .SUCCESS {
    //     fmt.eprintln("vkCreateFramebuffer failed:", vkres)
    //     err = .NotYetDetailed
    //     return
    //   }
  }


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

load_texture_from_file :: proc(ctx: ^Context, filepath: cstring) -> (rh: ResourceHandle, err: Error) {
  
  tex_width, tex_height, tex_channels: libc.int
  pixels := stbi.load(filepath, &tex_width, &tex_height, &tex_channels, STBI_rgb_alpha)
  if pixels == nil {
    err = .NotYetDetailed
    fmt.eprintln("Violin.load_texture_from_file: Failed to load image from file:", filepath)
    return
  }
  
  image_size := tex_width * tex_height * STBI_rgb_alpha
  fmt.println(pixels)
  // fmt.println("width:", tex_width, "height:", tex_height, "channels:", tex_channels, "image_size:", image_size)

  rh = load_image_sampler(ctx, tex_width, tex_height, tex_channels, .ReadOnly, pixels) or_return

  // append_to_collection((void ***)&p_vkrs->textures.items, &p_vkrs->textures.alloc, &p_vkrs->textures.count, texture);

  stbi.image_free(pixels)

  fmt.printf("loaded %s> width:%i height:%i channels:%i\n", filepath, tex_width, tex_height, tex_channels);

  return
}

create_uniform_buffer :: proc(using ctx: ^Context, size_in_bytes: u64, intended_usage: BufferUsage) -> (rh: ResourceHandle,
  err: Error) {
  #partial switch intended_usage {
    case .Dynamic:
      // Create the Buffer
      buffer_create_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size = auto_cast size_in_bytes,
        usage = {.UNIFORM_BUFFER, .TRANSFER_DST},
      }

      allocation_create_info := vma.AllocationCreateInfo {
        usage = .AUTO,
        flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD, .MAPPED},
      }
      
      rh = _create_resource(&ctx.resource_manager, .Buffer) or_return
      buffer: ^Buffer = auto_cast get_resource(&ctx.resource_manager, rh) or_return
      buffer.size = auto_cast size_in_bytes
      vkres := vma.CreateBuffer(vma_allocator, &buffer_create_info, &allocation_create_info, &buffer.buffer,
        &buffer.allocation, &buffer.allocation_info)
      if vkres != .SUCCESS {
        fmt.eprintln("create_uniform_buffer>vmaCreateBuffer failed:", vkres)
        err = .NotYetDetailed
        return
      }
    case:
      fmt.println("create_uniform_buffer() > Unsupported buffer usage:", intended_usage)
  }
return
}

// TODO -- allow/disable staging - test performance
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

  return .NotYetDetailed
}

create_vertex_buffer :: proc(using ctx: ^Context, vertex_data: rawptr, vertex_size_in_bytes: int,
  vertex_count: int) -> (rh: VertexBufferResourceHandle, err: Error) {
  // Create the resource
  rh = auto_cast _create_resource(&ctx.resource_manager, .VertexBuffer) or_return
  vertex_buffer: ^VertexBuffer = auto_cast get_resource_any(&ctx.resource_manager, auto_cast rh) or_return

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
  rh = auto_cast _create_resource(&ctx.resource_manager, .VertexBuffer) or_return
  index_buffer: ^IndexBuffer = auto_cast get_resource_any(&ctx.resource_manager, auto_cast rh) or_return

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