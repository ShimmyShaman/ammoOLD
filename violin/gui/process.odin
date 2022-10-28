package violin_gui

import "core:fmt"
import "core:mem"

import "vendor:sdl2"

import vi "../../violin"

handle_gui_event :: proc(gui: ^GUIRoot, event: ^sdl2.Event) -> (handled: bool, err: vi.Error) {
  return
}

update_gui :: proc(gui_root: ^GUIRoot) {
  for child in gui_root.children {
    _update_control_layout(child, gui_root.bounds)
  }
}

render_gui :: proc(using rctx: ^vi.RenderContext, stamprr: vi.StampRenderResourceHandle, gui_root: ^GUIRoot) -> (err: vi.Error) {
  return
}

// int mca_update_typical_node_layout_partially(mc_node *node, mc_rectf const *available_area, bool update_x,
//   bool update_y, bool update_width, bool update_height, bool update_children)
_update_control_layout :: proc(control: ^Control, available_area: Rectf, update_x: bool = true, update_y: bool = true,
    update_width: bool = true, update_height: bool = true, update_children: bool = true) {

  next: Rectf
  layout: ^_ControlLayout = &control._info._layout
  layout.requires_layout_update = false  
    
  // Width
  if update_width {
    // Width
    if layout.preferred_width != 0.0 {
      // Set to preferred width
      next.width = layout.preferred_width
    }
    else {
      // Padding adjusted from available
      next.width = available_area.width - layout.padding.right - layout.padding.left
    }
  }

  // Apply the determined extent
  if next.width > layout.determined_width_extent {
    next.width = layout.determined_width_extent
  }

  if next.width != control.bounds.width {
    control.bounds.width = next.width
    // TODO -- change/rerender flag?
  }

  // Height
  if update_height {
    // Height
    if layout.preferred_height != 0.0 {
      // Set to preferred height
      next.height = layout.preferred_height
    }
    else {
      // Padding adjusted from available
      next.height = available_area.height - layout.padding.top - layout.padding.bottom
    }
  }
  
  // Apply the determined extent
  if next.height > layout.determined_height_extent {
    next.height = layout.determined_height_extent
  }
  
  if next.height != control.bounds.height {
    control.bounds.height = next.height
    // TODO -- change/rerender flag?
  }

  // Left
  if update_x {
    switch layout.horizontal_alignment {
      case .Left:
        next.x = available_area.x + layout.padding.left
      case .Right:
        next.x = available_area.x + available_area.width - layout.padding.right - next.width
      case .Centred:
        next.x = available_area.x + layout.padding.left +
          (available_area.width - (layout.padding.left + next.width + layout.padding.right)) / 2.0
    }

    if next.x != control.bounds.x {
      control.bounds.x = next.x
      // TODO -- change/rerender flag?
    }
  }

  // Top
  if update_y {
    switch layout.vertical_alignment {
      case .Top:
        next.y = available_area.y + layout.padding.top
      case .Bottom:
        next.y = available_area.y + available_area.height - layout.padding.bottom - next.height
      case .Centred:
        next.y = available_area.y + layout.padding.top +
          (available_area.height - (layout.padding.bottom + next.height + layout.padding.top)) / 2.0
    }

    if next.y != control.bounds.y {
      control.bounds.y = next.y
      // TODO -- change/rerender flag?
    }
  }

  // Children
  if update_children {
    as_parent: ^_ParentControlInfo = cast(^_ParentControlInfo)control
    if as_parent.children != nil {
      for child in as_parent.children {
        _update_control_layout(child, control.bounds)
      }
    }
  }

  return
}