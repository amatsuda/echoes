# frozen_string_literal: true

require 'pty'
require 'io/console'
require 'json'
require 'securerandom'

module Echoes
  # Drives a per-pane subprocess (`embedded_shell_helper.rb`) that owns
  # the pty as its controlling tty and runs a `Rubish::REPL` in its own
  # session. Every external command rubish forks inherits the helper's
  # session/ctty, so Ctrl-C (ETX → SIGINT) works for any execution
  # shape — single command, pipeline, loop, sequence, conditional.
  #
  # The helper communicates with this class over a JSON-line control
  # pipe. Standard rubish output (prompts, command stdout/stderr) flows
  # through the pty in the usual way. The control pipe carries:
  #
  #   - synchronous queries: complete_at, prompt, prompt_segments,
  #     try_parse, tokenize, history, last_status, cwd, …
  #   - async events from helper to host: command_done, …
  #
  # API surface is identical to the previous in-process version so
  # callers (Pane, etc.) don't need to change.
  class EmbeddedShell
    HELPER_SCRIPT = File.expand_path('embedded_shell_helper.rb', __dir__)
    DEFAULT_SYNC_TIMEOUT = 5.0
    # Mirror of EmbeddedShellHelper::DONE_SENTINEL — the helper writes
    # this OSC sequence to the pty after a command's last output bytes
    # are flushed but before it sends the command_done event on the
    # control pipe. The pty reader scans for it and strips it; the
    # presence of the sentinel + the event together is what
    # `reap_if_done` waits for.
    DONE_SENTINEL = "\e]7771\a"

    def initialize
      ENV['GIT_PAGER'] ||= 'cat'
      ENV['PAGER']     ||= 'cat'

      @master, slave = PTY.open
      # Bidirectional JSON-line control pipes. Helper reads requests on
      # fd 3 and writes responses/events on fd 4.
      ctl_in_r,  ctl_in_w  = IO.pipe   # parent → helper
      ctl_out_r, ctl_out_w = IO.pipe   # helper → parent
      @control_write = ctl_in_w
      @control_read  = ctl_out_r
      @control_write.sync = true

      @output_buffer  = +''
      @output_lock    = Mutex.new
      @pending_lock   = Mutex.new
      @pending        = {}            # id → Queue
      @running        = false
      @last_status    = 0
      @last_cwd       = Dir.pwd

      load_paths = $LOAD_PATH.flat_map { |p| ['-I', p] }
      @helper_pid = Process.spawn(
        RbConfig.ruby, *load_paths, HELPER_SCRIPT,
        in: slave, out: slave, err: slave,
        3 => ctl_in_r, 4 => ctl_out_w,
        close_others: true,
      )
      slave.close
      ctl_in_r.close
      ctl_out_w.close

      @sentinel_seen = false
      @reader = Thread.new(@master) do |m|
        # Accumulator handles a sentinel that straddles two chunks.
        # Anything older than `DONE_SENTINEL.bytesize - 1` from the tail
        # is safe to flush; the rest stays back for next-iteration
        # overlap detection.
        acc = +''
        begin
          loop do
            chunk = m.readpartial(4096)
            acc << chunk
            while (idx = acc.index(DONE_SENTINEL))
              before = acc[0...idx]
              @output_lock.synchronize { @output_buffer << before } unless before.empty?
              acc = acc[(idx + DONE_SENTINEL.bytesize)..] || +''
              @sentinel_seen = true
            end
            keep = DONE_SENTINEL.bytesize - 1
            if acc.bytesize > keep
              flush_n = acc.bytesize - keep
              @output_lock.synchronize { @output_buffer << acc.byteslice(0, flush_n) }
              acc = acc.byteslice(flush_n, acc.bytesize - flush_n) || +''
            end
          end
        rescue EOFError, IOError, Errno::EIO
          # helper exited or was killed
        end
        @output_lock.synchronize { @output_buffer << acc } unless acc.empty?
      end

      @control_reader = Thread.new(@control_read) do |io|
        begin
          while (line = io.gets)
            handle_control_line(line)
          end
        rescue IOError, Errno::EIO
          # helper exited
        end
      end
    end

    # Submit a complete line of input. Returns immediately; output flows
    # through the pty asynchronously and `command_done` will set
    # @running back to false. The line is added to history (rubish-side)
    # by the helper before execution.
    def submit_line(line, rows: 24, cols: 80)
      return if running?
      @master.winsize = [rows, cols] rescue nil
      @running = true
      rpc_async('execute', line: line)
    end

    # Synchronous wrapper for scripts and tests that don't have a
    # dispatch loop. Submits and blocks until the command completes
    # (or `timeout` seconds pass — in which case ETX is sent).
    def submit_and_wait(line, rows: 24, cols: 80, timeout: 30)
      submit_line(line, rows: rows, cols: cols)
      deadline = Time.now + timeout
      while running?
        if Time.now > deadline
          interrupt
          break
        end
        sleep 0.01
      end
      reap_if_done
      nil
    end

    def running?
      @running
    end

    # Drain any output bytes the pty reader has buffered. Empty String
    # if none. Never blocks.
    def read_available_output
      @output_lock.synchronize do
        data = @output_buffer.dup
        @output_buffer.clear
        data
      end
    end

    # Write keystrokes to the pty master. The kernel's line discipline
    # routes them to whatever is reading on the slave (the running
    # command's stdin).
    def forward_input(bytes)
      @master.write(bytes)
    rescue IOError, Errno::EIO, Errno::EPIPE
    end

    # ETX. The line discipline converts to SIGINT delivered to the
    # foreground process group of the slave's controlling session —
    # which is the helper's session, so any rubish-forked child
    # receives it.
    def interrupt
      @master.write("\x03") rescue nil
    end

    # Updates the pty master's winsize. The kernel propagates to the
    # slave (which is the helper's ctty) and emits SIGWINCH to the
    # foreground process group, so vim/less/etc. repaint.
    def resize(rows:, cols:)
      @master.winsize = [rows, cols]
    rescue IOError, Errno::EIO
    end

    # Compatibility method the host calls each tick. With the helper
    # architecture the pty/ctty live for the pane's lifetime, but the
    # host still needs a one-shot "command finished" signal so it can
    # emit the next prompt. Returns true on the tick where BOTH the
    # control_out command_done event has arrived AND the pty sentinel
    # has been observed by the reader thread (so the caller's next
    # `read_available_output` is guaranteed to have drained the
    # command's last bytes).
    def reap_if_done
      return false unless @done_pending && @sentinel_seen
      @done_pending = false
      @sentinel_seen = false
      true
    end

    # ---- queries to the helper (synchronous) ----

    def complete_at(line:, point:)
      rpc_sync('complete', line: line, point: point) || []
    end

    def prompt
      rpc_sync('prompt') || ''
    end

    def prompt_segments
      (rpc_sync('prompt_segments') || []).map { |s| symbolize_segment(s) }
    end

    def continuation_prompt
      rpc_sync('continuation_prompt') || '> '
    end

    def try_parse(line)
      (rpc_sync('try_parse', line: line) || 'error').to_sym
    end

    def tokenize(line)
      (rpc_sync('tokenize', line: line) || []).map { |t| TokenView.new(t['type'].to_sym, t['value']) }
    end

    def history
      rpc_sync('history') || []
    end

    def last_status
      @last_status
    end

    def cwd
      # Cached from command_done events; only refresh on demand if
      # nothing has been run yet.
      @last_cwd ||= rpc_sync('cwd')
      @last_cwd
    end

    # Returns when the helper has exited and pipes are closed. For
    # tests / shutdown.
    def shutdown
      rpc_async('shutdown') rescue nil
      Process.waitpid(@helper_pid) rescue nil
      @master.close rescue nil
      @control_write.close rescue nil
      @control_read.close rescue nil
      @reader.join(1) rescue nil
      @control_reader.join(1) rescue nil
    end

    private

    # Mirror of Rubish::Lexer::Token's small interface (type/value)
    # over a value object so colorize_input doesn't need to know it
    # came across a pipe.
    TokenView = Struct.new(:type, :value)

    def handle_control_line(line)
      msg = JSON.parse(line) rescue nil
      return unless msg
      if msg.key?('event')
        handle_event(msg)
      elsif (id = msg['id'])
        queue = @pending_lock.synchronize { @pending.delete(id) }
        queue&.push(msg['result'])
      end
    end

    def handle_event(msg)
      case msg['event']
      when 'command_done'
        @last_status = msg['exit_status'].to_i
        @last_cwd    = msg['cwd'] if msg['cwd']
        @done_pending = true
        @running = false
      end
    end

    def rpc_async(op, **args)
      send_request(op, **args)
    end

    def rpc_sync(op, **args)
      id = SecureRandom.uuid
      queue = Queue.new
      @pending_lock.synchronize { @pending[id] = queue }
      send_request(op, id: id, **args)
      result = queue.pop_with_timeout(DEFAULT_SYNC_TIMEOUT) if queue.respond_to?(:pop_with_timeout)
      result = wait_with_timeout(queue, DEFAULT_SYNC_TIMEOUT) if result.nil?
      result
    rescue Errno::EPIPE, IOError
      nil
    end

    def wait_with_timeout(queue, timeout)
      deadline = Time.now + timeout
      until queue.closed? || queue.size > 0
        return nil if Time.now > deadline
        sleep 0.005
      end
      queue.pop
    end

    def send_request(op, **args)
      payload = {'op' => op}
      args.each { |k, v| payload[k.to_s] = v }
      @control_write.puts JSON.generate(payload)
    rescue Errno::EPIPE, IOError
    end

    def symbolize_segment(s)
      {
        text:      s['text'],
        fg:        s['fg'],
        bg:        s['bg'],
        bold:      s['bold'],
        italic:    s['italic'],
        underline: s['underline'],
        inverse:   s['inverse'],
      }
    end
  end
end
