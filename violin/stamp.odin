package violin

import "core:os"
import "core:fmt"
import "core:c/libc"
import "core:mem"
import "core:sync"
import "core:strings"

import vk "vendor:vulkan"
// import stb "vendor:stb/lib"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"
import vma "../deps/odin-vma"

Rect :: struct {
  x: i32,
  y: i32,
  w: i32,
  h: i32,
}

Color :: struct {
  r: u8,
  g: u8,
  b: u8,
  a: u8,
}
Color_White := Color {r = 255, g = 255, b = 255, a = 255}

Vertex2 :: struct {
  pos: [2]f32,
}

Vertex2UV :: struct {
  pos: [2]f32,
  uv: [2]f32,
}

// typedef struct mcr_font_resource {
//   const char *name;
//   float height;
//   float draw_vertical_offset;
//   mcr_texture_image *texture;
//   void *char_data;
// } mcr_font_resource;


init_stamp_batch_renderer :: proc(using ctx: ^Context, render_pass_config: RenderPassConfigFlags,
  uniform_buffer_size := 128 * 256) -> (stamph: StampRenderResourceHandle, err: Error) {
  // Create the resource
  stamph = auto_cast _create_resource(&resource_manager, .StampRenderResource) or_return
  stampr: ^StampRenderResource = auto_cast _get_resource(&resource_manager, auto_cast stamph) or_return

  // Create the render pass
  // HasPreviousColorPass = 0,
	// IsPresent            = 1,
  if .HasDepthBuffer in render_pass_config {
    err = .NotYetDetailed
    fmt.println("Error: init_stamp_batch_renderer>Depth buffer not supported in stamp batch renderer")
    return
  }
  // draw_rp_config, present_rp_config: RenderPassConfigFlags
  // draw_rp_config = {.HasPreviousColorPass}
  // if .HasPreviousColorPass not_in render_pass_config {
  //   stampr.clear_render_pass = create_render_pass(ctx, {}) or_return
  // }
  // if .IsPresent in render_pass_config {
  //   present_rp_config = {.HasPreviousColorPass, .IsPresent}
  // }
  // stampr.draw_render_pass = create_render_pass(ctx, draw_rp_config) or_return
  // fmt.println("created draw render pass:", stampr.draw_render_pass, "with config:", draw_rp_config)
  // if present_rp_config != nil {
  //   stampr.present_render_pass = create_render_pass(ctx, present_rp_config) or_return
  //   fmt.println("created present render pass:", stampr.present_render_pass, "with config:", present_rp_config)
  // }
  stampr.render_pass = create_render_pass(ctx, render_pass_config) or_return
  
  // Create the render programs
  vertices := [?]Vertex2 {
    {{0.0, 0.0},},
    {{1.0, 0.0},},
    {{0.0, 1.0},},
    {{1.0, 1.0},},
  }
  
  vertices_uv := [?]Vertex2UV{
    {{0.0, 0.0}, {0.0, 0.0}},
    {{1.0, 0.0}, {1.0, 0.0}},
    {{0.0, 1.0}, {0.0, 1.0}},
    {{1.0, 1.0}, {1.0, 1.0}},
  }
  
  indices := [?]u16{
    0, 1, 2,
    2, 1, 3,
  }

  get_shader_path :: proc(violin_package_relative_path: string, name: string) -> (shader_path: string, err: Error) {
    aerr: mem.Allocator_Error
    shader_path, aerr =  strings.concatenate_safe({violin_package_relative_path, name},
      context.temp_allocator)
    if aerr != .None {
      err = .AllocationFailed
    }
    return
  }

  // Bindings
  ubo_only_binding := [?]vk.DescriptorSetLayoutBinding {
    vk.DescriptorSetLayoutBinding {
      binding = 1,
      descriptorType = .UNIFORM_BUFFER,
      stageFlags = { .VERTEX },
      descriptorCount = 1,
      pImmutableSamplers = nil,
    },
  }

  ubo_and_texture_binding := [?]vk.DescriptorSetLayoutBinding {
    ubo_only_binding[0],
    vk.DescriptorSetLayoutBinding {
      binding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      stageFlags = { .FRAGMENT },
      descriptorCount = 1,
      pImmutableSamplers = nil,
    },
  }

  // Colored Rect Render Program
  vertex2_inputs := [?]InputAttribute {
    {
      format = .R32G32_SFLOAT,
      location = 0,
      offset = auto_cast offset_of(Vertex2, pos),
    },
  }
  render_program_create_info := RenderProgramCreateInfo {
    pipeline_config = PipelineCreateConfig {
      vertex_shader_filepath = get_shader_path(ctx.violin_package_relative_path, "violin/shaders/colored_rect.vert") or_return,
      fragment_shader_filepath = get_shader_path(ctx.violin_package_relative_path, "violin/shaders/colored_rect.frag") or_return,
      render_pass = stampr.render_pass,
    },
    vertex_size = size_of(Vertex2),
    buffer_bindings = ubo_only_binding[:],
    input_attributes = vertex2_inputs[:],
  }
  stampr.colored_rect_render_program = create_render_program(ctx, &render_program_create_info) or_return

  // Textured Rect Render Program
  vertex2UV_inputs := [?]InputAttribute {
    {
      format = .R32G32_SFLOAT,
      location = 0,
      offset = auto_cast offset_of(Vertex2UV, pos),
    },
    {
      format = .R32G32_SFLOAT,
      location = 1,
      offset = auto_cast offset_of(Vertex2UV, uv),
    },
  }
  render_program_create_info = RenderProgramCreateInfo {
    pipeline_config = PipelineCreateConfig {
      vertex_shader_filepath = get_shader_path(ctx.violin_package_relative_path, "violin/shaders/textured_rect.vert") or_return,
      fragment_shader_filepath = get_shader_path(ctx.violin_package_relative_path, "violin/shaders/textured_rect.frag") or_return,
      render_pass = stampr.render_pass,
    },
    vertex_size = size_of(Vertex2UV),
    buffer_bindings = ubo_and_texture_binding[:],
    input_attributes = vertex2UV_inputs[:],
  }
  stampr.textured_rect_render_program = create_render_program(ctx, &render_program_create_info) or_return
  
  // Uniform Buffer
  stampr.uniform_buffer.capacity = auto_cast (size_of(f32) * 8 * 256) // TODO -- appropriate size
  stampr.uniform_buffer.rh = create_uniform_buffer(ctx, stampr.uniform_buffer.capacity, .Dynamic) or_return

  // Ensure the created uniform buffer is HOST_VISIBLE for dynamic copying
  {
    ubr: ^Buffer = auto_cast _get_resource(&resource_manager, auto_cast stampr.uniform_buffer.rh) or_return
    mem_property_flags: vk.MemoryPropertyFlags
    vma.GetAllocationMemoryProperties(vma_allocator, ubr.allocation, &mem_property_flags)
    if vk.MemoryPropertyFlag.HOST_VISIBLE not_in mem_property_flags {
      fmt.eprintln("init_stamp_batch_renderer>buffer memory is not HOST_VISIBLE. Invalid Call")
      err = .NotYetDetailed
      return
    }

    props: vk.PhysicalDeviceProperties;
    vk.GetPhysicalDeviceProperties(physical_device, &props);
    stampr.uniform_buffer.device_min_block_alignment = props.limits.minUniformBufferOffsetAlignment
  }

  // TODO use triangle-fan? test performance difference
  stampr.colored_rect_vertex_buffer = create_vertex_buffer(ctx, auto_cast &vertices[0], size_of(Vertex2), 4) or_return
  stampr.textured_rect_vertex_buffer = create_vertex_buffer(ctx, auto_cast &vertices_uv[0], size_of(Vertex2UV), 4) or_return
  stampr.rect_index_buffer = create_index_buffer(ctx, auto_cast &indices[0], 6) or_return

  // parameter_data := [8]f32 {
  //   auto_cast 100 / cast(f32)ctx.swap_chain.extent.width,
  //   auto_cast 100 / cast(f32)ctx.swap_chain.extent.height,
  //   auto_cast 320 / cast(f32)ctx.swap_chain.extent.width,
  //   auto_cast 200 / cast(f32)ctx.swap_chain.extent.height,
  //   auto_cast 245 / 255.0,
  //   auto_cast 252 / 255.0,
  //   auto_cast 1 / 255.0,
  //   auto_cast 255 / 255.0,
  // }
  // write_to_buffer(ctx, stampr.uniform_buffer, auto_cast &parameter_data[0], auto_cast (size_of(f32) * 8)) or_return

  return
}

// Internal Function :: Use destroy_resource() instead
__release_stamp_render_resource :: proc(using ctx: ^Context, tdr: ^StampRenderResource) {
  destroy_index_buffer(ctx, tdr.rect_index_buffer)
  destroy_vertex_buffer(ctx, tdr.colored_rect_vertex_buffer)
  destroy_vertex_buffer(ctx, tdr.textured_rect_vertex_buffer)
  destroy_resource_any(ctx, tdr.uniform_buffer.rh)

  destroy_render_program(ctx, &tdr.colored_rect_render_program)
  destroy_render_program(ctx, &tdr.textured_rect_render_program)

  // if tdr.clear_render_pass != 0 do destroy_render_pass(ctx, tdr.clear_render_pass)
  destroy_render_pass(ctx, tdr.render_pass)
  // if tdr.present_render_pass != 0 do destroy_render_pass(ctx, tdr.present_render_pass)
}

stamp_begin :: proc(using rctx: ^RenderContext, stamp_handle: StampRenderResourceHandle) -> Error {
  stampr: ^StampRenderResource = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stamp_handle) or_return

  // if stampr.clear_render_pass != auto_cast 0 {
  //   _begin_render_pass(rctx, stampr.clear_render_pass) or_return
  // }

  // Delegate
  begin_render_pass(rctx, stampr.render_pass) or_return

  // Redefine status
  rctx.status = .StampRenderPass
  // rctx.followup_render_pass = stampr.present_render_pass

  // Reset Uniform Buffer Tracking
  stampr.uniform_buffer.utilization = 0

  return .Success
}

// @(private) _stamp_restart_render_pass :: proc(using rctx: ^RenderContext, stampr: ^StampRenderResource) -> Error {
//   if rctx.status != .StampRenderPass {
//     fmt.eprintln("_stamp_restart_render_pass>invalid status. Invalid Call")
//     return .InvalidState
//   }

//   // // End the current
//   // vk.CmdEndRenderPass(command_buffer)

//   // Delegate
//   begin_render_pass(rctx, stampr.draw_render_pass) or_return

//   // Redefine status
//   rctx.status = .StampRenderPass

//   // Reset Uniform Buffer Tracking
//   stampr.uniform_buffer.utilization = 0

//   return .Success
// }

stamp_colored_rect :: proc(using rctx: ^RenderContext, stamp_handle: StampRenderResourceHandle, rect: ^Rect, color: ^Color) -> Error {
  // Obtain the resources
  stampr: ^StampRenderResource = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stamp_handle) or_return
  vbuf: ^VertexBuffer = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stampr.colored_rect_vertex_buffer) or_return
  ibuf: ^IndexBuffer = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stampr.rect_index_buffer) or_return
  ubuf: ^Buffer = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stampr.uniform_buffer.rh) or_return

  // Write the input to the uniform buffer
  parameter_data := [8]f32 {
    auto_cast rect.x / cast(f32)rctx.ctx.swap_chain.extent.width,
    auto_cast rect.y / cast(f32)rctx.ctx.swap_chain.extent.height,
    auto_cast rect.w / cast(f32)rctx.ctx.swap_chain.extent.width,
    auto_cast rect.h / cast(f32)rctx.ctx.swap_chain.extent.height,
    auto_cast color.r / 255.0,
    auto_cast color.g / 255.0,
    auto_cast color.b / 255.0,
    auto_cast color.a / 255.0,
  }

  // Write to the HOST_VISIBLE memory
  ubo_offset: vk.DeviceSize = auto_cast stampr.uniform_buffer.utilization
  ubo_range: int : size_of(f32) * 8

  if ubo_offset + auto_cast ubo_range > stampr.uniform_buffer.capacity {
    fmt.eprintln("Error] stamp_colored_rect> stamp uniform buffer is full. Too many calls for initial buffer size.",
      "Consider increasing the buffer size")
    return .NotYetDetailed
  }
  
  // Update the uniform buffer utilization
  stampr.uniform_buffer.utilization += max(cast(vk.DeviceSize) ubo_range, stampr.uniform_buffer.device_min_block_alignment)
  
  // Write to the buffer
  copy_dst: rawptr = auto_cast (cast(uintptr)ubuf.allocation_info.pMappedData + auto_cast ubo_offset)
  mem.copy(copy_dst, auto_cast &parameter_data[0], ubo_range)

  // Setup viewport and clip --- TODO this ain't true
  _set_viewport_cmd(command_buffer, 0, 0, auto_cast ctx.swap_chain.extent.width,
    auto_cast ctx.swap_chain.extent.height)
  _set_scissor_cmd(command_buffer, 0, 0, ctx.swap_chain.extent.width, ctx.swap_chain.extent.height)

  // Queue Buffer Write
  MAX_DESC_SET_WRITES :: 8
  writes: [MAX_DESC_SET_WRITES]vk.WriteDescriptorSet
  buffer_infos: [1]vk.DescriptorBufferInfo
  buffer_info_index := 0
  write_index := 0
  
  // Allocate the descriptor set from the pool
  descriptor_set_index := descriptor_sets_index

  set_alloc_info := vk.DescriptorSetAllocateInfo {
    sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
    // Use the descriptor pool we created earlier (the one dedicated to this frame)
    descriptorPool = descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts = &stampr.colored_rect_render_program.descriptor_layout,
  }
  vkres := vk.AllocateDescriptorSets(ctx.device, &set_alloc_info, &descriptor_sets[descriptor_set_index])
  if vkres != .SUCCESS {
    fmt.eprintln("vkAllocateDescriptorSets failed:", vkres)
    return .NotYetDetailed
  }
  desc_set := descriptor_sets[descriptor_set_index]
  descriptor_sets_index += set_alloc_info.descriptorSetCount

  // Describe the uniform buffer binding
  buffer_infos[0].buffer = ubuf.buffer
  buffer_infos[0].offset = ubo_offset
  buffer_infos[0].range = auto_cast ubo_range

  // Element Vertex Shader Uniform Buffer
  write := &writes[write_index]
  write_index += 1

  write.sType = .WRITE_DESCRIPTOR_SET
  write.dstSet = desc_set
  write.descriptorCount = 1
  write.descriptorType = .UNIFORM_BUFFER
  write.pBufferInfo = &buffer_infos[0]
  write.dstArrayElement = 0
  write.dstBinding = stampr.colored_rect_render_program.layout_bindings[0].binding
  
  vk.UpdateDescriptorSets(ctx.device, auto_cast write_index, &writes[0], 0, nil)

  vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, stampr.colored_rect_render_program.pipeline.layout, 0, 1, &desc_set, 0, nil)

  vk.CmdBindPipeline(command_buffer, .GRAPHICS, stampr.colored_rect_render_program.pipeline.handle)

  vk.CmdBindIndexBuffer(command_buffer, ibuf.buffer, 0, ibuf.index_type) // TODO -- support other index types

  // const VkDeviceSize offsets[1] = {0};
  // vkCmdBindVertexBuffers(command_buffer, 0, 1, &cmd->render_program.data->vertices->buf, offsets);
  // // vkCmdDraw(command_buffer, 3 * 2 * 6, 1, 0, 0);
  // int index_draw_count = cmd->render_program.data->specific_index_draw_count;
  // if (!index_draw_count)
  //   index_draw_count = cmd->render_program.data->indices->capacity;
  offsets: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(command_buffer, 0, 1, &vbuf.buffer, &offsets)
  // TODO -- specific index draw count

  // // printf("index_draw_count=%i\n", index_draw_count);
  // // printf("cmd->render_program.data->indices->capacity=%i\n", cmd->render_program.data->indices->capacity);
  // // printf("cmd->render_program.data->specific_index_draw_count=%i\n",
  // //        cmd->render_program.data->specific_index_draw_count);

  // vkCmdDrawIndexed(command_buffer, index_draw_count, 1, 0, 0, 0);
  vk.CmdDrawIndexed(command_buffer, auto_cast ibuf.index_count, 1, 0, 0, 0) // TODO -- index_count as u32?
  // fmt.print("ibuf.index_count:", ibuf.index_count)

  return .Success
}

stamp_textured_rect :: proc(using rctx: ^RenderContext, stamp_handle: StampRenderResourceHandle, txh: TextureResourceHandle,
  rect: ^Rect, tint: ^Color = nil, sub_uv_coords: [4]f32 = {0.0, 0.0, 1.0, 1.0}) -> Error {
  // Obtain the resources
  stampr: ^StampRenderResource = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stamp_handle) or_return
  texture: ^Texture = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast txh) or_return
  vbuf: ^VertexBuffer = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stampr.textured_rect_vertex_buffer) or_return
  ibuf: ^IndexBuffer = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stampr.rect_index_buffer) or_return
  ubuf: ^Buffer = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast stampr.uniform_buffer.rh) or_return

  // Write the input to the uniform buffer
  tint_ := tint
  if tint_ == nil {
    tint_ = &Color_White
  }
  PARAM_COUNT :: 12
  parameter_data := [PARAM_COUNT]f32 {
    auto_cast rect.x / cast(f32)rctx.ctx.swap_chain.extent.width,
    auto_cast rect.y / cast(f32)rctx.ctx.swap_chain.extent.height,
    auto_cast rect.w / cast(f32)rctx.ctx.swap_chain.extent.width,
    auto_cast rect.h / cast(f32)rctx.ctx.swap_chain.extent.height,
    auto_cast tint_.r / 255.0,
    auto_cast tint_.g / 255.0,
    auto_cast tint_.b / 255.0,
    auto_cast tint_.a / 255.0,
    sub_uv_coords[0],
    sub_uv_coords[1],
    sub_uv_coords[2] - sub_uv_coords[0],
    sub_uv_coords[3] - sub_uv_coords[1],
  }

  // Write to the HOST_VISIBLE memory
  ubo_offset: vk.DeviceSize = auto_cast stampr.uniform_buffer.utilization
  ubo_range: int : size_of(f32) * PARAM_COUNT

  if ubo_offset + auto_cast ubo_range > stampr.uniform_buffer.capacity {
    fmt.eprintln("Error] stamp_colored_rect> stamp uniform buffer is full. Too many calls for initial buffer size.",
      "Consider increasing the buffer size")
    return .NotYetDetailed
  }
  
  // Update the uniform buffer utilization
  stampr.uniform_buffer.utilization += max(cast(vk.DeviceSize) ubo_range, stampr.uniform_buffer.device_min_block_alignment)
  
  // Write to the buffer
  copy_dst: rawptr = auto_cast (cast(uintptr)ubuf.allocation_info.pMappedData + auto_cast ubo_offset)
  mem.copy(copy_dst, auto_cast &parameter_data[0], ubo_range)

  // Setup viewport and clip --- TODO this ain't true
  _set_viewport_cmd(command_buffer, 0, 0, auto_cast ctx.swap_chain.extent.width,
    auto_cast ctx.swap_chain.extent.height)
  _set_scissor_cmd(command_buffer, 0, 0, ctx.swap_chain.extent.width, ctx.swap_chain.extent.height)

  // Queue Buffer Write
  MAX_DESC_SET_WRITES :: 8
  writes: [MAX_DESC_SET_WRITES]vk.WriteDescriptorSet
  buffer_infos: [1]vk.DescriptorBufferInfo
  image_sampler_infos: [1]vk.DescriptorImageInfo
  write_index := 0
  
  // Allocate the descriptor set from the pool
  descriptor_set_index := descriptor_sets_index

  set_alloc_info := vk.DescriptorSetAllocateInfo {
    sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
    // Use the descriptor pool we created earlier (the one dedicated to this frame)
    descriptorPool = descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts = &stampr.textured_rect_render_program.descriptor_layout,
  }
  vkres := vk.AllocateDescriptorSets(ctx.device, &set_alloc_info, &descriptor_sets[descriptor_set_index])
  if vkres != .SUCCESS {
    fmt.eprintln("vkAllocateDescriptorSets failed:", vkres)
    return .NotYetDetailed
  }
  desc_set := descriptor_sets[descriptor_set_index]
  descriptor_sets_index += set_alloc_info.descriptorSetCount

  // Describe the Vertex Shader Uniform Buffer
  {
    buffer_infos[0].buffer = ubuf.buffer
    buffer_infos[0].offset = ubo_offset
    buffer_infos[0].range = auto_cast ubo_range

    write := &writes[write_index]
    write_index += 1

    write.sType = .WRITE_DESCRIPTOR_SET
    write.dstSet = desc_set
    write.descriptorCount = 1
    write.descriptorType = .UNIFORM_BUFFER
    write.pBufferInfo = &buffer_infos[0]
    write.dstArrayElement = 0
    write.dstBinding = stampr.textured_rect_render_program.layout_bindings[0].binding
  }

  // Describe the Fragment Shader Combined Image Sampler
  {
    image_sampler: ^Texture = auto_cast _get_resource(&rctx.ctx.resource_manager, auto_cast txh) or_return

    image_sampler_info := &image_sampler_infos[0]
    image_sampler_info.imageLayout = .SHADER_READ_ONLY_OPTIMAL
    image_sampler_info.imageView = image_sampler.image_view
    image_sampler_info.sampler = image_sampler.sampler
    
    write := &writes[write_index]
    write_index += 1

    write.sType = .WRITE_DESCRIPTOR_SET
    write.dstSet = desc_set
    write.descriptorCount = 1
    write.descriptorType = .COMBINED_IMAGE_SAMPLER
    write.pImageInfo = image_sampler_info
    write.dstArrayElement = 0
    write.dstBinding = stampr.textured_rect_render_program.layout_bindings[1].binding
  }
  
  vk.UpdateDescriptorSets(ctx.device, auto_cast write_index, &writes[0], 0, nil)

  vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, stampr.textured_rect_render_program.pipeline.layout, 0, 1, &desc_set, 0, nil)

  vk.CmdBindPipeline(command_buffer, .GRAPHICS, stampr.textured_rect_render_program.pipeline.handle)

  vk.CmdBindIndexBuffer(command_buffer, ibuf.buffer, 0, ibuf.index_type) // TODO -- support other index types

  // const VkDeviceSize offsets[1] = {0};
  // vkCmdBindVertexBuffers(command_buffer, 0, 1, &cmd->render_program.data->vertices->buf, offsets);
  // // vkCmdDraw(command_buffer, 3 * 2 * 6, 1, 0, 0);
  // int index_draw_count = cmd->render_program.data->specific_index_draw_count;
  // if (!index_draw_count)
  //   index_draw_count = cmd->render_program.data->indices->capacity;
  offsets: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(command_buffer, 0, 1, &vbuf.buffer, &offsets)
  // TODO -- specific index draw count

  // // printf("index_draw_count=%i\n", index_draw_count);
  // // printf("cmd->render_program.data->indices->capacity=%i\n", cmd->render_program.data->indices->capacity);
  // // printf("cmd->render_program.data->specific_index_draw_count=%i\n",
  // //        cmd->render_program.data->specific_index_draw_count);

  // vkCmdDrawIndexed(command_buffer, index_draw_count, 1, 0, 0, 0);
  vk.CmdDrawIndexed(command_buffer, auto_cast ibuf.index_count, 1, 0, 0, 0) // TODO -- index_count as u32?
  // fmt.print("ibuf.index_count:", ibuf.index_count)

  return .Success
}

// vi.stamp_text(rctx, handle_2d, cmd_t.font, cmd_t.text, cmd_t.pos.x, cmd_t.pos.y, cmd_t.color)
stamp_text :: proc(using rctx: ^RenderContext, stamp_handle: StampRenderResourceHandle, font_handle: FontResourceHandle,
  text: string, #any_int pos_x: int, #any_int pos_y: int, color: ^Color) -> Error {
  // Text Length
  text_length := len(text)
  if text_length == 0 do return .Success
  
  // Get the font image
  font: ^Font = auto_cast _get_resource(&ctx.resource_manager, auto_cast font_handle) or_return
  font_texture: ^Texture = auto_cast _get_resource(&ctx.resource_manager, auto_cast font.texture) or_return

  align_x: f32 = auto_cast pos_x
  align_y: f32 = auto_cast pos_y

  letter: u8
  clip: vk.Rect2D
  cc: ^Rect
  q: stbtt.aligned_quad
  width, height, scale_multiplier: f32

  for c := 0; c < text_length; c += 1 {
    letter = text[c]

    // fmt.println("align_x:", align_x)
    // if align_x > auto_cast font_texture.width do break
    //   letter = cmd->print_text.text[c];
    //   if (letter < 32 || letter > 127) {
    //     printf("TODO character not supported.\n");
    //     return VK_SUCCESS;
    //   }
    //   // printf("printing character '%c' %i\n", letter, (int)letter);
    letter = text[c]
    if letter < 32 || letter > 127 {
      fmt.eprintln(args={"ERROR>stamp_text: character '", letter, "' not supported."}, sep = "")
      return .NotYetDetailed
    }
  
    // Source texture bounds
    stbtt.GetBakedQuad(font.char_data, auto_cast font_texture.width, auto_cast font_texture.height, auto_cast letter - 32,
      &align_x, &align_y, &q, true)
    // TODO -- opengl_fill_rule??? // 1=opengl & d3d10+,0=d3d9 -- should be true, nothing on net about it
  
    rect: Rect = {auto_cast q.x0, auto_cast q.y0, auto_cast (q.x1 - q.x0), auto_cast (q.y1 - q.y0)}
    fmt.println("letter:", letter, "rect:", rect, "q.s0:", q.s0, "q.t0:", q.t0, "q.s1:", q.s1, "q.t1:", q.t1)
    stamp_textured_rect(rctx, stamp_handle, font.texture, &rect, color, {q.s0, q.t0, q.s1, q.t1})

  // -- FROM HERE --
  //   //   // TODO -- figure out why this won't work
  //   //   // if (letter == ' ') {
  //   //   //   // No need to print empty space (yet...)
  //   //   //   continue;
  //   //   // }
  
  //   //   // printf("mrt-2\n");
  //   //   // stbtt_bakedchar *b = font->char_data + (letter - 32);
  //   //   // q.y0 += b->y1 - b->y0;
  //   //   // q.y1 += b->y1 - b->y0;
  //   //   // {
  //   //   //   // opengl y invert
  //   //   //   float t = q.y1;
  //   //   //   q.y1 += (q.y1 - q.y0);
  //   //   //   q.y0 = t;
  //   //   // }
  //   //   width = q.x1 - q.x0;
  //   //   height = q.y1 - q.y0;
  //   width = q.x1 - q.x0
  //   height = q.y1 - q.y0
  
  //   //   q.y0 += font->draw_vertical_offset;
  //   //   q.y1 += font->draw_vertical_offset;
  //   q.y0 += font.draw_vertical_offset
  //   q.y1 += font.draw_vertical_offset
  
  //   // Determine the clip
  //   clip.offset.x = auto_cast (q.x0 < 0 ? 0 : q.x0)
  //   clip.offset.y = auto_cast (q.y0 < 0 ? 0 : q.y0)
  //   clip.extent.width = auto_cast width
  //   clip.extent.height = auto_cast height
  //   {
  //     // TODO -- clipping
  //     // cc = auto_cast &cmd_t.clip
  //   //     if (cc->extents.width && cc->extents.height) {
  //   //       if (clip.offset.x < cc->offset.x)
  //   //         clip.offset.x = cc->offset.x;
  //   //       if (clip.offset.y < cc->offset.y)
  //   //         clip.offset.y = cc->offset.y;
  //   //       if (clip.offset.x + clip.extent.width > cc->offset.x + cc->extents.width) {
  //   //         if (cc->offset.x + cc->extents.width <= clip.offset.x)
  //   //           clip.extent.width = 0U;
  //   //         else
  //   //           clip.extent.width = cc->offset.x + cc->extents.width - clip.offset.x;
  //   //       }
  //   //       if (clip.offset.y + clip.extent.height > cc->offset.y + cc->extents.height) {
  //   //         if (cc->offset.y + cc->extents.height <= clip.offset.y)
  //   //           clip.extent.height = 0U;
  //   //         else
  //   //           clip.extent.height = cc->offset.y + cc->extents.height - clip.offset.y;
  //   //       }
  //   }
  
  //   //     if (clip.extent.width <= 0U || clip.extent.height <= 0U)
  //   //       continue;
  //   //     if (clip.offset.x >= image_render->image_width || clip.offset.y >= image_render->image_height)
  //   //       continue;
  //   if clip.extent.width <= 0 || clip.extent.height <= 0 do continue
  //   if clip.offset.x >= font.image.width || clip.offset.y >= font.image.height do continue
  
  //   //     // if (clip.extent.width > 4444) {
  //   //     //   printf("clip:%i %i %u %u || cc:%i %i %u %u\n", clip.offset.x, clip.offset.y, clip.extent.width,
  //   //     //          clip.extent.height, cc->offset.x, cc->offset.y, cc->extents.width, cc->extents.height);
  //   //     // }
  //   // }
  //   //   // printf("baked_quad: s0=%.2f s1==%.2f t0=%.2f t1=%.2f x0=%.2f x1=%.2f y0=%.2f y1=%.2f xoff=%.2f yoff=%.2f\n",
  //   //   // q.s0,
  //   //   //        q.s1, q.t0, q.t1, q.x0, q.x1, q.y0, q.y1, font->char_data->xoff, font->char_data->yoff);
  //   //   // printf("align_x=%.2f align_y=%.2f\n", align_x, align_y);
  //   //   // printf("font->draw_vertical_offset=%.2f\n", font->draw_vertical_offset);
  
  //   // Vertex Uniform Buffer Object  -- TODO do checking on copy_buffer->index and data array size
  //   //   vert_data_scale_offset *vert_ubo_data = (vert_data_scale_offset *)&copy_buffer->data[copy_buffer->index];
  //   //   copy_buffer->index += sizeof(vert_data_scale_offset);
  //   //   MCassert(copy_buffer->index < MRT_SEQUENCE_COPY_BUFFER_SIZE, "BUFFER TOO SMALL");
  //   //   // printf("mrt-2a\n");
  
  //   //   scale_multiplier =
  //   //       1.f / (float)(image_render->image_width < image_render->image_height ? image_render->image_width
  //   //                                                                            : image_render->image_height);
  //   //   vert_ubo_data->scale.x = 2.f * width * scale_multiplier;
  //   //   vert_ubo_data->scale.y = 2.f * height * scale_multiplier;
  //   //   vert_ubo_data->offset.x = -1.0f + 2.0f * q.x0 / (float)(image_render->image_width) +
  //   //                             1.0f * (float)width / (float)(image_render->image_width);
  //   //   vert_ubo_data->offset.y = -1.0f + 2.0f * q.y0 / (float)(image_render->image_height) +
  //   //                             1.0f * (float)height / (float)(image_render->image_height);
  
  //   //   // printf("mrt-3\n");
  //   //   // Fragment Data
  //   //   frag_ubo_tint_texcoordbounds *frag_ubo_data =
  //   //       (frag_ubo_tint_texcoordbounds *)&copy_buffer->data[copy_buffer->index];
  //   //   copy_buffer->index += sizeof(frag_ubo_tint_texcoordbounds);
  //   //   MCassert(copy_buffer->index < MRT_SEQUENCE_COPY_BUFFER_SIZE, "BUFFER TOO SMALL");
  
  //   //   memcpy(&frag_ubo_data->tint, &cmd->print_text.color, sizeof(float) * 4);
  //   //   frag_ubo_data->tex_coord_bounds.s0 = q.s0;
  //   //   frag_ubo_data->tex_coord_bounds.s1 = q.s1;
  //   //   frag_ubo_data->tex_coord_bounds.t0 = q.t0;
  //   //   frag_ubo_data->tex_coord_bounds.t1 = q.t1;
  
  //   //   // Setup viewport and clip
  //   //   // printf("image_render : %f, %f\n",  (float)image_render->image_width,  (float)image_render->image_height);
  //   //   set_viewport_cmd(command_buffer, 0.f, 0.f, (float)image_render->image_width, (float)image_render->image_height);
  //   //   vkCmdSetScissor(command_buffer, 0, 1, &clip);
  //   //   // set_scissor_cmd(command_buffer, clip.offset.x, clip.offset.y, clip.extent.width, clip.extent.height);
  
  //   //   // printf("mrt-4\n");
  //   //   // Allocate the descriptor set from the pool.
  //   //   VkDescriptorSetAllocateInfo setAllocInfo = {};
  //   //   setAllocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  //   //   setAllocInfo.pNext = NULL;
  //   //   setAllocInfo.descriptorPool = p_vkrs->descriptor_pool;
  //   //   setAllocInfo.descriptorSetCount = 1;
  //   //   setAllocInfo.pSetLayouts = &p_vkrs->font_prog.descriptor_layout;
  
  //   //   unsigned int descriptor_set_index = p_vkrs->descriptor_sets_count;
  //   //   // printf("cmd->text:'%s' descriptor_set_index=%u\n", cmd->print_text.text, descriptor_set_index);
  //   //   res = vkAllocateDescriptorSets(p_vkrs->device, &setAllocInfo, &p_vkrs->descriptor_sets[descriptor_set_index]);
  //   //   VK_CHECK(res, "vkAllocateDescriptorSets");
  
  //   //   VkDescriptorSet desc_set = p_vkrs->descriptor_sets[descriptor_set_index];
  //   //   p_vkrs->descriptor_sets_count += setAllocInfo.descriptorSetCount;
  
  //   //   // Queue Buffer and Descriptor Writes
  //   //   const unsigned int MAX_DESC_SET_WRITES = 4;
  //   //   VkWriteDescriptorSet writes[MAX_DESC_SET_WRITES];
  //   //   VkDescriptorBufferInfo buffer_infos[MAX_DESC_SET_WRITES];
  //   //   int buffer_info_index = 0;
  //   //   int write_index = 0;
  
  //   //   // printf("mrt-5\n");
  //   //   VkDescriptorBufferInfo *vert_ubo_info = &buffer_infos[buffer_info_index++];
  //   //   res = mrt_write_desc_and_queue_render_data(p_vkrs, sizeof(vert_data_scale_offset), vert_ubo_data, vert_ubo_info);
  //   //   VK_CHECK(res, "mrt_write_desc_and_queue_render_data");
  
  //   //   VkDescriptorBufferInfo *frag_ubo_info = &buffer_infos[buffer_info_index++];
  //   //   res = mrt_write_desc_and_queue_render_data(p_vkrs, sizeof(frag_ubo_tint_texcoordbounds), frag_ubo_data,
  //   //                                              frag_ubo_info);
  //   //   VK_CHECK(res, "mrt_write_desc_and_queue_render_data");
  
  //   //   // printf("mrt-6\n");
  //   //   // Global Vertex Shader Uniform Buffer
  //   //   VkWriteDescriptorSet *write = &writes[write_index++];
  //   //   write->sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  //   //   write->pNext = NULL;
  //   //   write->dstSet = desc_set;
  //   //   write->descriptorCount = 1;
  //   //   write->descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  //   //   write->pBufferInfo = &copy_buffer->vpc_desc_buffer_info;
  //   //   write->dstArrayElement = 0;
  //   //   write->dstBinding = 0;
  
  //   //   // Element Vertex Shader Uniform Buffer
  //   //   write = &writes[write_index++];
  //   //   write->sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  //   //   write->pNext = NULL;
  //   //   write->dstSet = desc_set;
  //   //   write->descriptorCount = 1;
  //   //   write->descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  //   //   write->pBufferInfo = vert_ubo_info;
  //   //   write->dstArrayElement = 0;
  //   //   write->dstBinding = 1;
  
  //   //   // Element Fragment Shader Uniform Buffer
  //   //   write = &writes[write_index++];
  //   //   write->sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  //   //   write->pNext = NULL;
  //   //   write->dstSet = desc_set;
  //   //   write->descriptorCount = 1;
  //   //   write->descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
  //   //   write->pBufferInfo = frag_ubo_info;
  //   //   write->dstArrayElement = 0;
  //   //   write->dstBinding = 2;
  
  //   //   // printf("mrt-7\n");
  //   //   VkDescriptorImageInfo image_sampler_info = {};
  //   //   image_sampler_info.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  //   //   image_sampler_info.imageView = font_image->view;
  //   //   image_sampler_info.sampler = font_image->sampler;
  
  //   //   // Element Fragment Shader Combined Image Sampler
  //   //   write = &writes[write_index++];
  //   //   write->sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  //   //   write->pNext = NULL;
  //   //   write->dstSet = desc_set;
  //   //   write->descriptorCount = 1;
  //   //   write->descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  //   //   write->pImageInfo = &image_sampler_info;
  //   //   write->dstArrayElement = 0;
  //   //   write->dstBinding = 3;
  
  //   //   // printf("mrt-8\n");
  //   //   vkUpdateDescriptorSets(p_vkrs->device, write_index, writes, 0, NULL);
  
  //   //   vkCmdBindDescriptorSets(command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, p_vkrs->font_prog.pipeline_layout, 0, 1,
  //   //                           &desc_set, 0, NULL);
  
  //   //   vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, p_vkrs->font_prog.pipeline);
  
  //   //   const VkDeviceSize offsets[1] = {0};
  //   //   vkCmdBindVertexBuffers(command_buffer, 0, 1, &p_vkrs->textured_shape_vertices.buf, offsets);
  
  //   //   vkCmdDraw(command_buffer, 2 * 3, 1, 0, 0);
  //   //   // printf("mrt-9\n");
  }

  // free(cmd->print_text.text);
  return .Success
}