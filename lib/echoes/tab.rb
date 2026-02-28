# frozen_string_literal: true

module Echoes
  class Tab
    attr_reader :pane_tree
    attr_accessor :title

    def initialize(command:, rows:, cols:)
      @command = command
      @rows = rows
      @cols = cols
      pane = Pane.new(command: command, rows: rows, cols: cols)
      @pane_tree = PaneTree.new(pane)
      @title = pane.title
    end

    # --- Active pane delegation (backward compatibility) ---

    def active_pane
      @pane_tree.active_pane
    end

    def screen
      active_pane.screen
    end

    def parser
      active_pane.parser
    end

    def pty_read
      active_pane.pty_read
    end

    def pty_write
      active_pane.pty_write
    end

    def pty_pid
      active_pane.pty_pid
    end

    def scroll_offset
      active_pane.scroll_offset
    end

    def scroll_offset=(val)
      active_pane.scroll_offset = val
    end

    def scroll_accum
      active_pane.scroll_accum
    end

    def scroll_accum=(val)
      active_pane.scroll_accum = val
    end

    # --- Pane operations ---

    def split_vertical
      new_pane = create_pane
      layout = @pane_tree.layout(0, 0, @cols, @rows)
      current_rect = layout.find { |r| r[:pane] == active_pane }
      if current_rect
        half_cols = current_rect[:w] / 2
        active_pane.resize(current_rect[:h], half_cols)
        new_pane.resize(current_rect[:h], current_rect[:w] - half_cols)
      end
      @pane_tree.split(active_pane, :vertical, new_pane)
      new_pane
    end

    def split_horizontal
      new_pane = create_pane
      layout = @pane_tree.layout(0, 0, @cols, @rows)
      current_rect = layout.find { |r| r[:pane] == active_pane }
      if current_rect
        half_rows = current_rect[:h] / 2
        active_pane.resize(half_rows, current_rect[:w])
        new_pane.resize(current_rect[:h] - half_rows, current_rect[:w])
      end
      @pane_tree.split(active_pane, :horizontal, new_pane)
      new_pane
    end

    def close_active_pane
      return false if @pane_tree.single_pane?

      pane = active_pane
      @pane_tree.remove(pane)
      pane.close
      resize_panes
      true
    end

    def next_pane
      @pane_tree.active_pane = @pane_tree.next_pane(active_pane)
    end

    def prev_pane
      @pane_tree.active_pane = @pane_tree.prev_pane(active_pane)
    end

    def panes
      @pane_tree.panes
    end

    # --- Lifecycle ---

    def alive?
      panes.any?(&:alive?)
    end

    def resize(rows, cols)
      @rows = rows
      @cols = cols
      resize_panes
    end

    def close
      panes.each(&:close)
    end

    private

    def create_pane
      Pane.new(command: @command, rows: @rows, cols: @cols)
    end

    def resize_panes
      layout = @pane_tree.layout(0, 0, @cols, @rows)
      layout.each do |rect|
        rect[:pane].resize(rect[:h], rect[:w])
      end
    end
  end
end
