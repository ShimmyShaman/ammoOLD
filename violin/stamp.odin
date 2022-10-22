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

// typedef struct mcr_font_resource {
//   const char *name;
//   float height;
//   float draw_vertical_offset;
//   mcr_texture_image *texture;
//   void *char_data;
// } mcr_font_resource;

FontResource :: struct {
  name: string,
  height: f32,
  draw_vertical_offset: f32,
  texture: ^ResourceHandle,
  char_data: rawptr,
}


init_stamp_batch_renderer :: proc(using ctx: ^Context, render_pass_config: RenderPassConfigFlags,
  uniform_buffer_size := 256 * 8 * 4) -> (stamph: StampRenderResourceHandle, err: Error) {
  // Create the resource
  stamph = auto_cast _create_resource(&resource_manager, .StampRenderResource) or_return
  stampr: ^StampRenderResource = auto_cast get_resource_any(&resource_manager, auto_cast stamph) or_return

  // Create the render pass
  // HasPreviousColorPass = 0,
	// IsPresent            = 1,
  if .HasDepthBuffer in render_pass_config {
    err = .NotYetDetailed
    fmt.println("Error: init_stamp_batch_renderer>Depth buffer not supported in stamp batch renderer")
    return
  }
  draw_rp_config, present_rp_config: RenderPassConfigFlags
  draw_rp_config = {.HasPreviousColorPass}
  if .HasPreviousColorPass not_in render_pass_config {
    stampr.clear_render_pass = create_render_pass(ctx, {}) or_return
  }
  if .IsPresent in render_pass_config {
    present_rp_config = {.HasPreviousColorPass, .IsPresent}
  }
  stampr.draw_render_pass = create_render_pass(ctx, draw_rp_config) or_return
  fmt.println("created draw render pass:", stampr.draw_render_pass, "with config:", draw_rp_config)
  if present_rp_config != nil {
    stampr.present_render_pass = create_render_pass(ctx, present_rp_config) or_return
    fmt.println("created present render pass:", stampr.present_render_pass, "with config:", present_rp_config)
  }
  
  // Create the render programs
  Vertex :: struct {
    pos: [2]f32,
  }
  
  vertices := [?]Vertex{
    {{0.0, 0.0},},
    {{1.0, 0.0},},
    {{0.0, 1.0},},
    {{1.0, 1.0},},
  }
  // Vertex :: struct {
  //   pos: [2]f32,
  // }
  
  // vertices := [?]Vertex{
  //   {{-1.0, -1.0}, {0.0, 0.0, 0.0}},
  //   {{ 1.0, -1.0}, {1.0, 0.0, 0.0}},
  //   {{ 1.0, 1.0}, {1.0, 1.0, 0.0}},
  //   {{-1.0, 1.0}, {0.0, 1.0, 1.0}},
  // }
  indices := [?]u16{
    0, 1, 2,
    2, 1, 3,
  }

  color_bindings := [?]vk.DescriptorSetLayoutBinding {
    vk.DescriptorSetLayoutBinding {
      binding = 1,
      descriptorType = .UNIFORM_BUFFER,
      stageFlags = { .VERTEX },
      descriptorCount = 1,
      pImmutableSamplers = nil,
    },
  }

  // bindings := [?]vk.DescriptorSetLayoutBinding {
  //   vk.DescriptorSetLayoutBinding {
  //     binding = 1,
  //     descriptorType = .COMBINED_IMAGE_SAMPLER,
  //     stageFlags = { .FRAGMENT },
  //     descriptorCount = 1,
  //     pImmutableSamplers = nil,
  //   },
  // }

  inputs := [?]InputAttribute {
    {
      format = .R32G32_SFLOAT,
      location = 0,
      offset = auto_cast offset_of(Vertex, pos),
    },
  }

  vert_shader_path, ae1 :=  strings.concatenate_safe({ctx.violin_package_relative_path, "violin/shaders/colored_rect.vert"},
    context.temp_allocator)
  if ae1 != .None {
    err = .AllocationFailed
    return
  }
  fmt.println("vert_shader_path:", vert_shader_path)
  // defer delete(vert_shader_path)
  frag_shader_path, ae2 :=  strings.concatenate_safe({ctx.violin_package_relative_path, "violin/shaders/colored_rect.frag"},
    context.temp_allocator)
  if ae2 != .None {
    err = .AllocationFailed
    return
  }
  // defer delete_string(frag_shader_path)

  colored_rect_rpci := RenderProgramCreateInfo {
    pipeline_config = PipelineCreateConfig {
      vertex_shader_filepath = vert_shader_path, // TODO
      fragment_shader_filepath = frag_shader_path,
      render_pass = stampr.draw_render_pass,
    },
    vertex_size = size_of(Vertex),
    buffer_bindings = color_bindings[:],
    input_attributes = inputs[:],
  }
  stampr.colored_rect_render_program = create_render_program(ctx, &colored_rect_rpci) or_return
  
  // Uniform Buffer
  stampr.uniform_buffer.capacity = auto_cast (size_of(f32) * 8 * 256) // TODO -- appropriate size
  stampr.uniform_buffer.rh = create_uniform_buffer(ctx, stampr.uniform_buffer.capacity, .Dynamic) or_return

  // Ensure the created uniform buffer is HOST_VISIBLE for dynamic copying
  {
    ubr: ^Buffer = auto_cast get_resource_any(&resource_manager, auto_cast stampr.uniform_buffer.rh) or_return
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
  stampr.rect_vertex_buffer = create_vertex_buffer(ctx, auto_cast &vertices[0], size_of(Vertex), 4) or_return
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
  destroy_vertex_buffer(ctx, tdr.rect_vertex_buffer)
  destroy_resource_any(ctx, tdr.uniform_buffer.rh)

  destroy_render_program(ctx, &tdr.colored_rect_render_program)

  if tdr.clear_render_pass != 0 do destroy_render_pass(ctx, tdr.clear_render_pass)
  destroy_render_pass(ctx, tdr.draw_render_pass)
  if tdr.present_render_pass != 0 do destroy_render_pass(ctx, tdr.present_render_pass)
}

stamp_begin :: proc(using rctx: ^RenderContext, stamp_handle: StampRenderResourceHandle) -> Error {
  stampr: ^StampRenderResource = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast stamp_handle) or_return

  if stampr.clear_render_pass != auto_cast 0 {
    _begin_render_pass(rctx, stampr.clear_render_pass) or_return
  }

  // Delegate
  begin_render_pass(rctx, stampr.draw_render_pass) or_return

  // Redefine status
  rctx.status = .StampRenderPass
  rctx.followup_render_pass = stampr.present_render_pass

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
  stampr: ^StampRenderResource = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast stamp_handle) or_return
  vbuf: ^VertexBuffer = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast stampr.rect_vertex_buffer) or_return
  ibuf: ^IndexBuffer = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast stampr.rect_index_buffer) or_return
  ubuf: ^Buffer = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast stampr.uniform_buffer.rh) or_return

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

// vi.stamp_text(rctx, handle_2d, cmd_t.font, cmd_t.text, cmd_t.pos.x, cmd_t.pos.y, cmd_t.color)
stamp_text :: proc(using rctx: ^RenderContext, )