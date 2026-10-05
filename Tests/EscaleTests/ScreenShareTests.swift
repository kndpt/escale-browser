// Exercise the shipped compatibility script in JavaScriptCore. These tests
// protect the native capture contract; WebKit's encoder and real permission
// picker are checked separately by the local media fixture.

import JavaScriptCore
import Testing
@testable import Escale

struct ScreenShareTests {
    @Test func captureContract() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var calls = 0, observedThis, observedArgs, failCapture = false;
        var rejection = new Error('capture denied');
        var detail = {contentHint: ''}, motion = {contentHint: 'motion'};
        var unsupported = Object.defineProperty({}, 'contentHint', {
          get() { return ''; }, set() { throw new Error('unsupported'); }
        });
        var audio = {contentHint: ''};
        var stream = {getVideoTracks() { return [detail, motion, unsupported]; }, getAudioTracks() { return [audio]; }};
        class MediaDevices {
          getDisplayMedia(...args) {
            calls++; observedThis = this; observedArgs = args;
            return failCapture ? Promise.reject(rejection) : Promise.resolve(stream);
          }
          getUserMedia() { return 'camera unchanged'; }
        }
        globalThis.MediaDevices = MediaDevices;
        var devices = new MediaDevices();
        var camera = MediaDevices.prototype.getUserMedia;
        var options = {video: {frameRate: 30}, audio: false};
        """)
        context.evaluateScript(try Bundled.text("screen-share.js"))
        #expect(context.exception == nil)
        context.evaluateScript("""
        var passed = false;
        devices.getDisplayMedia(options).then(result => {
          passed = result === stream && detail.contentHint === 'detail'
            && motion.contentHint === 'motion' && audio.contentHint === ''
            && observedThis === devices && observedArgs[0] === options
            && calls === 1 && MediaDevices.prototype.getUserMedia === camera;
        });
        """)
        #expect(context.objectForKeyedSubscript("passed")?.toBool() == true)
        context.evaluateScript("""
        failCapture = true;
        var rejected = false;
        devices.getDisplayMedia(options).catch(error => { rejected = error === rejection && calls === 2; });
        """)
        #expect(context.objectForKeyedSubscript("rejected")?.toBool() == true)
    }

    @Test func absentOrLockedAPI() throws {
        for setup in ["", "globalThis.MediaDevices = class {}; Object.defineProperty(MediaDevices.prototype, 'getDisplayMedia', {value: function original() {}, configurable: false});"] {
            let context = try #require(JSContext())
            context.evaluateScript(setup)
            context.evaluateScript(try Bundled.text("screen-share.js"))
            #expect(context.exception == nil)
        }
    }
}
