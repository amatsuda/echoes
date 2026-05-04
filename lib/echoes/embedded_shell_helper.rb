# frozen_string_literal: true

# Per-pane subprocess that owns the pty as its controlling tty and
# runs Rubish::REPL on behalf of the parent Echoes process. By living
# in its own session and claiming the slave as ctty (TIOCSCTTY),
# every child rubish forks for an external command inherits the
# session/ctty — so ETX (Ctrl-C) the parent writes to the master
# becomes a SIGINT delivered by the line discipline to the foreground
# process group. Loops/pipelines now work because the session leader
# (this helper) stays alive across multiple forks.
#
# Communication with the parent:
#   - stdin  / stdout / stderr (fds 0/1/2) = pty slave (= controlling tty).
#       Rubish writes its prompts and command output to fd 1; children
#       read from fd 0.
#   - fd 3 = control_in: JSON-line messages from the parent.
#   - fd 4 = control_out: JSON-line responses + async events to parent.
#
# Wire format: one JSON object per line. Requests carry a string id;
# responses echo it. Async events have no id and use a "event" key.

require 'json'
require 'fiddle/import'
require 'rubish'
require 'rubish/runtime/command'
require 'reline'

module Echoes
  module HelperLibc
    extend Fiddle::Importer
    dlload Fiddle::Handle::DEFAULT
    extern 'int tcsetpgrp(int, int)'
  end

  class EmbeddedShellHelper
    DARWIN_TIOCSCTTY = 0x20007461

    def initialize
      Process.setsid rescue nil
      STDIN.ioctl(DARWIN_TIOCSCTTY, 0) rescue nil
      # After claiming ctty, explicitly set the slave's foreground
      # process group to ours. Without this, the line discipline has
      # nowhere to deliver SIGINT (the kernel doesn't do it automatically
      # on macOS via TIOCSCTTY) and Ctrl-C is silently lost.
      HelperLibc.tcsetpgrp(0, Process.getpgrp) rescue nil
      # The helper and any rubish-forked child share the helper's
      # process group (= slave's foreground pgrp once we claim ctty).
      # ETX → SIGINT is delivered to that whole group. We want:
      #   - the forked external command to terminate (its default
      #     handler does this after exec)
      #   - the helper *process* to survive (so the pane keeps running)
      #   - the rubish *command thread* to abort (so a for-loop's body
      #     stops iterating instead of just dropping the current sleep
      #     and starting the next one).
      # A Ruby trap-with-block survives across exec as SIG_DFL (kernel
      # only preserves SIG_IGN), so the exec'd binary still gets the
      # default-terminate behavior. The block runs on the helper main
      # thread; from there we raise Interrupt on the command thread.
      Signal.trap('INT')  { @command_thread&.raise(Interrupt) rescue nil }
      Signal.trap('QUIT') { @command_thread&.raise(Interrupt) rescue nil }
      no_rc = ENV['ECHOES_HELPER_NO_RC'] == '1'
      @repl = Rubish::REPL.new(no_rc: no_rc)
      # Rubish normally calls these from its `run` loop, which we
      # bypass — the line editor and prompt rendering live in echoes.
      # Drive them explicitly so ~/.rubishrc et al take effect,
      # default aliases land in the env, and history is restored.
      @repl.send(:setup_default_aliases) rescue nil
      @repl.send(:load_config) rescue nil
      @repl.send(:load_history) rescue nil unless no_rc
      @control_in  = IO.for_fd(3, 'r')
      @control_out = IO.for_fd(4, 'w')
      @control_out.sync = true
      @write_lock = Mutex.new
      @command_thread = nil
    end

    def run
      while (line = @control_in.gets)
        msg = (JSON.parse(line) rescue nil)
        next unless msg
        dispatch(msg)
      end
    end

    private

    def dispatch(msg)
      op = msg['op']
      case op
      when 'execute'           then handle_execute(msg)
      when 'complete'          then reply(msg, @repl.complete_at(line: msg['line'], point: msg['point']))
      when 'prompt'            then reply(msg, @repl.prompt)
      when 'prompt_segments'   then reply(msg, segments_to_array(@repl.prompt_segments))
      when 'continuation_prompt' then reply(msg, @repl.send(:continuation_prompt))
      when 'try_parse'         then reply(msg, @repl.try_parse(msg['line']).to_s)
      when 'tokenize'          then reply(msg, tokens_for(msg['line']))
      when 'history'           then reply(msg, Reline::HISTORY.to_a)
      when 'last_status'       then reply(msg, @repl.instance_variable_get(:@last_status) || 0)
      when 'cwd'               then reply(msg, Dir.pwd)
      when 'resize'            then handle_resize(msg)
      when 'shutdown'          then exit 0
      end
    end

    # OSC 7771 used as an end-of-command sentinel so the host can be
    # certain it has drained all of this command's pty output before
    # acting on the command_done event. (control_out and the pty are
    # separate channels with no inherent ordering.) The host's pty
    # reader scans for this sequence and strips it.
    DONE_SENTINEL = "\e]7771\a"

    def handle_execute(msg)
      line = msg['line'].to_s
      Reline::HISTORY << line unless line.empty? || line.strip.empty?

      @command_thread = Thread.new do
        interrupted = false
        begin
          @repl.send(:execute, line)
          STDOUT.flush rescue nil
          STDERR.flush rescue nil
        rescue Interrupt
          interrupted = true
          # SIGINT propagated by the trap; let the rest of the
          # rubish runtime unwind, then fall through to command_done.
          STDOUT.write "\r\n" rescue nil
          STDOUT.flush rescue nil
        rescue => e
          STDERR.puts "rubish: #{e.class}: #{e.message}"
        end
        status = @repl.instance_variable_get(:@last_status) || (interrupted ? 130 : 0)
        # Sentinel first (must be in pty kernel buffer before host
        # observes command_done), then the structured event.
        STDOUT.write DONE_SENTINEL rescue nil
        STDOUT.flush rescue nil
        emit_event('command_done', exit_status: status, cwd: Dir.pwd)
      end
      reply(msg, 'started')
    end

    def handle_resize(msg)
      rows = msg['rows'].to_i
      cols = msg['cols'].to_i
      STDIN.winsize = [rows, cols]
    rescue Errno::EINVAL, Errno::ENOTTY
      # ignore
    ensure
      reply(msg, 'ok')
    end

    def reply(msg, result)
      id = msg['id']
      return unless id
      send_json('id' => id, 'result' => result)
    end

    def emit_event(event, **payload)
      send_json('event' => event, **payload)
    end

    def send_json(obj)
      @write_lock.synchronize do
        @control_out.puts JSON.generate(obj)
      end
    rescue Errno::EPIPE
      # parent went away
      exit 0
    end

    def tokens_for(line)
      @repl.tokenize(line).map { |t| {'type' => t.type.to_s, 'value' => t.value.to_s} }
    end

    def segments_to_array(segs)
      (segs || []).map do |s|
        {
          'text'      => s[:text].to_s,
          'fg'        => s[:fg],
          'bg'        => s[:bg],
          'bold'      => !!s[:bold],
          'italic'    => !!s[:italic],
          'underline' => !!s[:underline],
          'inverse'   => !!s[:inverse],
        }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Echoes::EmbeddedShellHelper.new.run
end
