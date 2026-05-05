# frozen_string_literal: true

require_relative 'objc'

module Echoes
  # Thin wrapper around `[NSUserDefaults initWithSuiteName:]` for
  # cross-launch persistence of small user-tweaked values (font size,
  # …). The on-disk plist lives at `~/Library/Preferences/<SUITE>.plist`
  # and `defaults read|write|delete <SUITE>` from the shell works as
  # expected.
  #
  # We use an explicit suite name rather than `standardUserDefaults`
  # because echoes runs under `bundle exec exe/echoes` (no Info.plist
  # bundle ID) and as a future `.app`. A fixed suite gives stable
  # storage across both.
  module Preferences
    SUITE = 'jp.dio.echoes'

    def self.defaults
      @defaults ||= begin
        obj = ObjC::MSG_PTR.call(ObjC.cls('NSUserDefaults'), ObjC.sel('alloc'))
        ObjC::MSG_PTR_1.call(obj, ObjC.sel('initWithSuiteName:'), ObjC.nsstring(SUITE))
      end
    end

    # Returns the stored Float for `key`, or `default` if the key isn't
    # set. We round-trip through `objectForKey:` so we can distinguish
    # "missing" from "set to 0.0" — `doubleForKey:` collapses both.
    def self.fetch_double(key, default:)
      obj = ObjC::MSG_PTR_1.call(defaults, ObjC.sel('objectForKey:'), ObjC.nsstring(key.to_s))
      return default if obj.null?
      ObjC::MSG_RET_D.call(obj, ObjC.sel('doubleValue'))
    end

    def self.set_double(key, value)
      ObjC::MSG_VOID_D_1.call(defaults, ObjC.sel('setDouble:forKey:'),
                              value.to_f, ObjC.nsstring(key.to_s))
    end

    def self.delete(key)
      ObjC::MSG_VOID_1.call(defaults, ObjC.sel('removeObjectForKey:'),
                            ObjC.nsstring(key.to_s))
    end
  end
end
