# frozen_string_literal: true

require 'fiddle'

module Echoes
  module ObjC
    LIBOBJC = Fiddle.dlopen('/usr/lib/libobjc.A.dylib')
    APPKIT = Fiddle.dlopen('/System/Library/Frameworks/AppKit.framework/AppKit')
    FOUNDATION = Fiddle.dlopen('/System/Library/Frameworks/Foundation.framework/Foundation')

    # Type aliases
    P = Fiddle::TYPE_VOIDP
    D = Fiddle::TYPE_DOUBLE
    L = Fiddle::TYPE_LONG
    I = Fiddle::TYPE_INT
    V = Fiddle::TYPE_VOID

    # Core runtime functions
    GetClass = Fiddle::Function.new(LIBOBJC['objc_getClass'], [P], P)
    RegisterName = Fiddle::Function.new(LIBOBJC['sel_registerName'], [P], P)
    AllocateClassPair = Fiddle::Function.new(LIBOBJC['objc_allocateClassPair'], [P, P, I], P)
    AddMethod = Fiddle::Function.new(LIBOBJC['class_addMethod'], [P, P, P, P], I)
    RegisterClassPair = Fiddle::Function.new(LIBOBJC['objc_registerClassPair'], [P], V)
    GetMethodImpl = Fiddle::Function.new(LIBOBJC['class_getMethodImplementation'], [P, P], P)
    AddProtocol = Fiddle::Function.new(LIBOBJC['class_addProtocol'], [P, P], I)
    GetProtocol = Fiddle::Function.new(LIBOBJC['objc_getProtocol'], [P], P)

    # objc_msgSend variants for different signatures
    def self.new_msg(args, ret)
      Fiddle::Function.new(LIBOBJC['objc_msgSend'], args, ret)
    end

    MSG_PTR       = new_msg([P, P], P)              # id = msg(id, SEL)
    MSG_PTR_1     = new_msg([P, P, P], P)            # id = msg(id, SEL, id)
    MSG_PTR_2     = new_msg([P, P, P, P], P)         # id = msg(id, SEL, id, id)
    MSG_PTR_L     = new_msg([P, P, L], P)            # id = msg(id, SEL, long)
    MSG_PTR_1L    = new_msg([P, P, P, L], P)           # id = msg(id, SEL, id, long)
    MSG_VOID      = new_msg([P, P], V)               # void = msg(id, SEL)
    MSG_VOID_1    = new_msg([P, P, P], V)            # void = msg(id, SEL, id)
    MSG_VOID_2    = new_msg([P, P, P, P], V)         # void = msg(id, SEL, id, id)
    MSG_VOID_4    = new_msg([P, P, P, P, P, P], V)  # void = msg(id, SEL, id, id, id, id)
    MSG_PTR_3     = new_msg([P, P, P, P, P], P)     # id = msg(id, SEL, id, id, id)
    MSG_VOID_I    = new_msg([P, P, I], V)            # void = msg(id, SEL, int)
    MSG_VOID_L    = new_msg([P, P, L], V)            # void = msg(id, SEL, long)
    MSG_VOID_2D   = new_msg([P, P, D, D], V)         # void = msg(id, SEL, double, double)
    MSG_RET_D     = new_msg([P, P], D)               # double = msg(id, SEL)
    MSG_RET_D_1   = new_msg([P, P, P], D)            # double = msg(id, SEL, id)
    MSG_RET_L     = new_msg([P, P], L)               # long = msg(id, SEL)

    # CGRect as 4 doubles
    MSG_PTR_RECT  = new_msg([P, P, D, D, D, D], P)  # initWithFrame:
    MSG_VOID_RECT = new_msg([P, P, D, D, D, D], V)  # NSRectFill equivalent

    # initWithContentRect:styleMask:backing:defer:
    MSG_PTR_RECT_L_L_I = new_msg([P, P, D, D, D, D, L, L, I], P)

    # drawAtPoint:withAttributes: (NSPoint = 2 doubles + id)
    MSG_VOID_PT_1 = new_msg([P, P, D, D, P], V)

    # colorWithRed:green:blue:alpha: (4 doubles)
    MSG_PTR_4D = new_msg([P, P, D, D, D, D], P)

    # fontWithName:size: (id, double)
    MSG_PTR_1D = new_msg([P, P, P, D], P)

    # monospacedSystemFontOfSize:weight: (2 doubles)
    MSG_PTR_2D = new_msg([P, P, D, D], P)

    # scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:
    MSG_PTR_D_P_P_P_I = new_msg([P, P, D, P, P, P, I], P)

    # NSRectFill C function
    NSRectFill = Fiddle::Function.new(APPKIT['NSRectFill'], [D, D, D, D], V)

    # Cocoa constants
    NSWindowStyleMaskTitled         = 1 << 0
    NSWindowStyleMaskClosable       = 1 << 1
    NSWindowStyleMaskMiniaturizable = 1 << 2
    NSWindowStyleMaskResizable      = 1 << 3
    NSWindowStyleMaskDefault = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
    NSBackingStoreBuffered = 2

    NSEventModifierFlagShift   = 1 << 17
    NSEventModifierFlagControl = 1 << 18
    NSEventModifierFlagOption  = 1 << 19
    NSEventModifierFlagCommand    = 1 << 20
    NSEventModifierFlagNumericPad = 1 << 21

    # Selector cache
    SEL_CACHE = {}

    def self.cls(name)
      GetClass.call(name)
    end

    def self.sel(name)
      SEL_CACHE[name] ||= RegisterName.call(name)
    end

    def self.retain(obj)
      MSG_PTR.call(obj, sel('retain'))
    end

    def self.release(obj)
      MSG_VOID.call(obj, sel('release'))
    end

    def self.nsstring(str)
      MSG_PTR_1.call(cls('NSString'), sel('stringWithUTF8String:'), str)
    end

    def self.to_ruby_string(nsstring_ptr)
      cstr = MSG_PTR.call(nsstring_ptr, sel('UTF8String'))
      cstr.to_s.force_encoding(Encoding::UTF_8)
    end

    def self.nsdict(hash)
      dict = MSG_PTR.call(cls('NSMutableDictionary'), sel('dictionary'))
      hash.each do |key, value|
        MSG_VOID_2.call(dict, sel('setObject:forKey:'), value, key)
      end
      dict
    end

    def self.nsnumber_int(val)
      MSG_PTR_L.call(cls('NSNumber'), sel('numberWithInteger:'), val)
    end

    def self.define_class(name, superclass_name, methods)
      super_cls = cls(superclass_name)
      new_cls = AllocateClassPair.call(super_cls, name, 0)
      methods.each do |sel_name, (type_encoding, closure)|
        AddMethod.call(new_cls, sel(sel_name), closure, type_encoding)
      end
      RegisterClassPair.call(new_cls)
      new_cls
    end

    # AppKit string constant accessors
    def self.appkit_const(name)
      ptr = Fiddle::Pointer.new(APPKIT[name])
      Fiddle::Pointer.new(ptr[0, Fiddle::SIZEOF_VOIDP].unpack1('J'))
    end

    NSFontAttributeName            = appkit_const('NSFontAttributeName')
    NSForegroundColorAttributeName = appkit_const('NSForegroundColorAttributeName')
    NSUnderlineStyleAttributeName      = appkit_const('NSUnderlineStyleAttributeName')
    NSStrikethroughStyleAttributeName  = appkit_const('NSStrikethroughStyleAttributeName')
    NSPasteboardTypeString         = appkit_const('NSPasteboardTypeString')

    # CoreGraphics framework
    COREGRAPHICS = Fiddle.dlopen('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')

    CGColorSpaceCreateDeviceRGB = Fiddle::Function.new(COREGRAPHICS['CGColorSpaceCreateDeviceRGB'], [], P)
    CGColorSpaceRelease         = Fiddle::Function.new(COREGRAPHICS['CGColorSpaceRelease'], [P], V)
    CGBitmapContextCreate       = Fiddle::Function.new(COREGRAPHICS['CGBitmapContextCreate'], [P, L, L, L, L, P, I], P)
    CGBitmapContextCreateImage  = Fiddle::Function.new(COREGRAPHICS['CGBitmapContextCreateImage'], [P], P)
    CGContextDrawImage          = Fiddle::Function.new(COREGRAPHICS['CGContextDrawImage'], [P, D, D, D, D, P], V)
    CGContextSaveGState         = Fiddle::Function.new(COREGRAPHICS['CGContextSaveGState'], [P], V)
    CGContextRestoreGState      = Fiddle::Function.new(COREGRAPHICS['CGContextRestoreGState'], [P], V)
    CGContextTranslateCTM       = Fiddle::Function.new(COREGRAPHICS['CGContextTranslateCTM'], [P, D, D], V)
    CGContextScaleCTM           = Fiddle::Function.new(COREGRAPHICS['CGContextScaleCTM'], [P, D, D], V)
    CGImageRelease              = Fiddle::Function.new(COREGRAPHICS['CGImageRelease'], [P], V)
    CGContextRelease            = Fiddle::Function.new(COREGRAPHICS['CGContextRelease'], [P], V)

    # kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault
    KCGImageAlphaPremultipliedLast = 1

    # CoreText framework
    CORETEXT = Fiddle.dlopen('/System/Library/Frameworks/CoreText.framework/CoreText')

    # CTFontCreateForString(CTFontRef currentFont, CFStringRef string, CFRange range) -> CTFontRef
    # CFRange is {CFIndex, CFIndex} = {long, long}, decomposed into 2 GPR args on arm64
    CTFontCreateForString = Fiddle::Function.new(CORETEXT['CTFontCreateForString'], [P, P, L, L], P)
  end
end
