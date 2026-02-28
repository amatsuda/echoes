# frozen_string_literal: true

module Echoes
  class PaneTree
    class SplitNode
      attr_accessor :direction, :ratio, :left, :right

      # direction: :vertical (left/right split with vertical divider)
      #            :horizontal (top/bottom split with horizontal divider)
      # ratio: 0.0..1.0, fraction allocated to left/top child
      def initialize(direction:, ratio: 0.5, left:, right:)
        @direction = direction
        @ratio = ratio
        @left = left
        @right = right
      end
    end

    class PaneNode
      attr_accessor :pane

      def initialize(pane)
        @pane = pane
      end
    end

    attr_reader :root
    attr_accessor :active_pane

    def initialize(pane)
      @root = PaneNode.new(pane)
      @active_pane = pane
    end

    # Split the active pane in the given direction, returning the new pane
    def split(pane, direction, new_pane)
      node = find_node(@root, pane)
      return nil unless node

      old_node = PaneNode.new(pane)
      new_node = PaneNode.new(new_pane)
      split_node = SplitNode.new(direction: direction, left: old_node, right: new_node)

      replace_node(node, split_node)
      @active_pane = new_pane
      new_pane
    end

    # Remove a pane, promoting its sibling
    def remove(pane)
      return nil if single_pane?

      parent = find_parent(@root, pane)
      return nil unless parent

      sibling = if pane_in_subtree?(parent.left, pane)
                  parent.right
                else
                  parent.left
                end

      replace_node(parent, sibling)

      if @active_pane == pane
        @active_pane = panes.first
      end
      pane
    end

    # Calculate layout rectangles for all panes
    # Returns [{pane:, x:, y:, w:, h:}, ...]
    def layout(x, y, w, h)
      layout_node(@root, x, y, w, h)
    end

    # Flat list of all panes (in-order traversal)
    def panes
      collect_panes(@root)
    end

    # Cycle to next pane
    def next_pane(current)
      list = panes
      idx = list.index(current)
      return list.first unless idx
      list[(idx + 1) % list.size]
    end

    # Cycle to previous pane
    def prev_pane(current)
      list = panes
      idx = list.index(current)
      return list.last unless idx
      list[(idx - 1) % list.size]
    end

    def single_pane?
      @root.is_a?(PaneNode)
    end

    def pane_count
      panes.size
    end

    private

    def find_node(node, pane)
      case node
      when PaneNode
        node if node.pane == pane
      when SplitNode
        find_node(node.left, pane) || find_node(node.right, pane)
      end
    end

    def find_parent(node, pane)
      return nil unless node.is_a?(SplitNode)

      if (node.left.is_a?(PaneNode) && node.left.pane == pane) ||
         (node.right.is_a?(PaneNode) && node.right.pane == pane)
        return node
      end

      find_parent(node.left, pane) || find_parent(node.right, pane)
    end

    def pane_in_subtree?(node, pane)
      case node
      when PaneNode
        node.pane == pane
      when SplitNode
        pane_in_subtree?(node.left, pane) || pane_in_subtree?(node.right, pane)
      end
    end

    def replace_node(target, replacement)
      if target == @root
        @root = replacement
        return
      end

      parent = find_parent_of_node(@root, target)
      return unless parent

      if parent.left == target
        parent.left = replacement
      else
        parent.right = replacement
      end
    end

    def find_parent_of_node(node, target)
      return nil unless node.is_a?(SplitNode)

      if node.left == target || node.right == target
        return node
      end

      find_parent_of_node(node.left, target) || find_parent_of_node(node.right, target)
    end

    def layout_node(node, x, y, w, h)
      case node
      when PaneNode
        [{pane: node.pane, x: x, y: y, w: w, h: h}]
      when SplitNode
        if node.direction == :vertical
          left_w = (w * node.ratio).to_i
          right_w = w - left_w
          layout_node(node.left, x, y, left_w, h) +
            layout_node(node.right, x + left_w, y, right_w, h)
        else # :horizontal
          top_h = (h * node.ratio).to_i
          bottom_h = h - top_h
          layout_node(node.left, x, y, w, top_h) +
            layout_node(node.right, x, y + top_h, w, bottom_h)
        end
      else
        []
      end
    end

    def collect_panes(node)
      case node
      when PaneNode
        [node.pane]
      when SplitNode
        collect_panes(node.left) + collect_panes(node.right)
      else
        []
      end
    end
  end
end
