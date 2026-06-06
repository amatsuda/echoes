# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "echoes"

require "test-unit"

# Test-only helpers for swapping singleton methods without firing
# "method redefined" warnings. Defining these at the top level
# would attach them as Object's private instance methods — visible
# everywhere in the process during the test run and capable of
# accidentally shadowing library code with the same name. Keep
# them scoped to this module and call via TestHelpers.foo.
module TestHelpers
  # Replace `receiver`'s singleton method `name` with `replacement`.
  # define_singleton_method warns when clobbering an existing
  # definition; removing the old entry first turns the new one
  # into a fresh add. Used by the stub patterns in the dispatch
  # tests (stub_decoder, with_decoder, etc.) that intentionally
  # swap a method around the yield.
  def self.replace_singleton_method(receiver, name, &replacement)
    klass = receiver.singleton_class
    klass.send(:remove_method, name) if klass.method_defined?(name) || klass.private_method_defined?(name)
    receiver.define_singleton_method(name, &replacement)
  end

  # Same shape for alias_method on the singleton — alias_method
  # warns when the destination already names a method.
  def self.replace_singleton_alias(receiver, new_name, old_name)
    klass = receiver.singleton_class
    klass.send(:remove_method, new_name) if klass.method_defined?(new_name) || klass.private_method_defined?(new_name)
    klass.send(:alias_method, new_name, old_name)
  end
end
