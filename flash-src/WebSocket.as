// Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
// License: New BSD License
// Reference: http://dev.w3.org/html5/websockets/
// Reference: http://tools.ietf.org/html/draft-hixie-thewebsocketprotocol-31

package {

import flash.display.*;
import flash.events.*;
import flash.external.*;
import flash.net.*;
import flash.system.*;
import flash.utils.*;
import mx.core.*;
import mx.controls.*;
import mx.events.*;
import mx.utils.*;
import com.adobe.net.proxies.RFC2817Socket;
import com.gsolo.encryption.MD5;

[Event(name="message", type="WebSocketMessageEvent")]
[Event(name="open", type="flash.events.Event")]
[Event(name="close", type="flash.events.Event")]
[Event(name="error", type="flash.events.Event")]
[Event(name="stateChange", type="WebSocketStateEvent")]
public class WebSocket extends EventDispatcher {
  
  private static var CONNECTING:int = 0;
  private static var OPEN:int = 1;
  private static var CLOSING:int = 2;
  private static var CLOSED:int = 3;
  
  private var socket:RFC2817Socket;
  private var main:WebSocketMain;
  private var url:String;
  private var scheme:String;
  private var host:String;
  private var port:uint;
  private var path:String;
  private var origin:String;
  private var protocol:String;
  private var buffer:ByteArray = new ByteArray();
  private var headerState:int = 0;
  private var readyState:int = CONNECTING;
  private var bufferedAmount:int = 0;
  private var headers:String;
  private var noiseChars:Array;
  private var expectedDigest:String;

  public function WebSocket(
      main:WebSocketMain, url:String, protocol:String,
      proxyHost:String = null, proxyPort:int = 0,
      headers:String = null) {
    this.main = main;
    initNoiseChars();
    this.url = url;
    var m:Array = url.match(/^(\w+):\/\/([^\/:]+)(:(\d+))?(\/.*)?$/);
    if (!m) main.fatal("SYNTAX_ERR: invalid url: " + url);
    this.scheme = m[1];
    this.host = m[2];
    this.port = parseInt(m[4] || "80");
    this.path = m[5] || "/";
    this.origin = main.getOrigin();
    this.protocol = protocol;
    // if present and not the empty string, headers MUST end with \r\n
    // headers should be zero or more complete lines, for example
    // "Header1: xxx\r\nHeader2: yyyy\r\n"
    this.headers = headers;
    
    socket = new RFC2817Socket();
            
    // if no proxy information is supplied, it acts like a normal Socket
    // @see RFC2817Socket::connect
    if (proxyHost != null && proxyPort != 0){      
      socket.setProxyInfo(proxyHost, proxyPort);
    } 
    
    socket.addEventListener(Event.CLOSE, onSocketClose);
    socket.addEventListener(Event.CONNECT, onSocketConnect);
    socket.addEventListener(IOErrorEvent.IO_ERROR, onSocketIoError);
    socket.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSocketSecurityError);
    socket.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
    socket.connect(host, port);
  }
  
  public function send(data:String):int {
    if (readyState == OPEN) {
      socket.writeByte(0x00);
      socket.writeUTFBytes(data);
      socket.writeByte(0xff);
      socket.flush();
      main.log("sent: " + data);
      return -1;
    } else if (readyState == CLOSED) {
      var bytes:ByteArray = new ByteArray();
      bytes.writeUTFBytes(data);
      bufferedAmount += bytes.length; // not sure whether it should include \x00 and \xff
      // We use return value to let caller know bufferedAmount because we cannot fire
      // stateChange event here which causes weird error:
      // > You are trying to call recursively into the Flash Player which is not allowed.
      return bufferedAmount;
    } else {
      main.fatal("INVALID_STATE_ERR: invalid state");
      return 0;
    }
  }
  
  public function close():void {
    main.log("close");
    try {
      socket.close();
    } catch (ex:Error) { }
    readyState = CLOSED;
    // We don't fire any events here because it causes weird error:
    // > You are trying to call recursively into the Flash Player which is not allowed.
    // We do something equivalent in JavaScript WebSocket#close instead.
  }
  
  public function getReadyState():int {
    return readyState;
  }
  
  public function getBufferedAmount():int {
    return bufferedAmount;
  }
  
  private function onSocketConnect(event:Event):void {
    main.log("connected");
    var hostValue:String = host + (port == 80 ? "" : ":" + port);
    var cookie:String = "";
    if (main.getCallerHost() == host) {
      cookie = ExternalInterface.call("function(){return document.cookie}");
    }
    var key1:String = generateKey();
    var key2:String = generateKey();
    var key3:String = generateKey3();
    expectedDigest = getSecurityDigest(key1, key2, key3);
    var opt:String = "";
    if (protocol) opt += "WebSocket-Protocol: " + protocol + "\r\n";
    // if caller passes additional headers they must end with "\r\n"
    if (headers) opt += headers;
    
    var req:String = StringUtil.substitute(
      "GET {0} HTTP/1.1\r\n" +
      "Upgrade: WebSocket\r\n" +
      "Connection: Upgrade\r\n" +
      "Host: {1}\r\n" +
      "Origin: {2}\r\n" +
      "Cookie: {3}\r\n" +
      "Sec-WebSocket-Key1: {4}\r\n" +
      "Sec-WebSocket-Key2: {5}\r\n" +
      "{6}" +
      "\r\n",
      path, hostValue, origin, cookie, key1, key2, opt);
    main.log("request header:\n" + req);
    socket.writeUTFBytes(req);
    main.log("sent key3: " + key3);
    writeBytes(key3);
    socket.flush();
  }

  private function onSocketClose(event:Event):void {
    main.log("closed");
    readyState = CLOSED;
    notifyStateChange();
    dispatchEvent(new Event("close"));
  }

  private function onSocketIoError(event:IOErrorEvent):void {
    var message:String;
    if (readyState == CONNECTING) {
      message = "cannot connect to Web Socket server at " + url + " (IoError)";
    } else {
      message = "error communicating with Web Socket server at " + url + " (IoError)";
    }
    onError(message);
  }

  private function onSocketSecurityError(event:SecurityErrorEvent):void {
    var message:String;
    if (readyState == CONNECTING) {
      message =
          "cannot connect to Web Socket server at " + url + " (SecurityError)\n" +
          "make sure the server is running and Flash socket policy file is correctly placed";
    } else {
      message = "error communicating with Web Socket server at " + url + " (SecurityError)";
    }
    onError(message);
  }
  
  private function onError(message:String):void {
    var state:int = readyState;
    if (state == CLOSED) return;
    main.error(message);
    close();
    notifyStateChange();
    dispatchEvent(new Event(state == CONNECTING ? "close" : "error"));
  }

  private function onSocketData(event:ProgressEvent):void {
    var pos:int = buffer.length;
    socket.readBytes(buffer, pos);
    for (; pos < buffer.length; ++pos) {
      if (headerState < 4) {
        // try to find "\r\n\r\n"
        if ((headerState == 0 || headerState == 2) && buffer[pos] == 0x0d) {
          ++headerState;
        } else if ((headerState == 1 || headerState == 3) && buffer[pos] == 0x0a) {
          ++headerState;
        } else {
          headerState = 0;
        }
        if (headerState == 4) {
          var headerStr:String = buffer.readUTFBytes(pos + 1);
          main.log("response header:\n" + headerStr);
          if (!validateHeader(headerStr)) return;
          makeBufferCompact();
          pos = -1;
        }
      } else if (headerState == 4) {
        if (pos == 15) {
          var replyDigest:String = readBytes(buffer, 16);
          main.log("reply digest: " + replyDigest);
          if (replyDigest != expectedDigest) {
            onError("digest doesn't match: " + replyDigest + " != " + expectedDigest);
            return;
          }
          headerState = 5;
          makeBufferCompact();
          pos = -1;
          readyState = OPEN;
          notifyStateChange();
          dispatchEvent(new Event("open"));
        }
      } else {
        if (buffer[pos] == 0xff) {
          if (buffer.readByte() != 0x00) {
            onError("data must start with \\x00");
            return;
          }
          var data:String = buffer.readUTFBytes(pos - 1);
          main.log("received: " + data);
          dispatchEvent(new WebSocketMessageEvent("message", encodeURIComponent(data)));
          buffer.readByte();
          makeBufferCompact();
          pos = -1;
        }
      }
    }
  }
  
  private function validateHeader(headerStr:String):Boolean {
    var lines:Array = headerStr.split(/\r\n/);
    if (!lines[0].match(/^HTTP\/1.1 101 /)) {
      onError("bad response: " + lines[0]);
      return false;
    }
    var header:Object = {};
    for (var i:int = 1; i < lines.length; ++i) {
      if (lines[i].length == 0) continue;
      var m:Array = lines[i].match(/^(\S+): (.*)$/);
      if (!m) {
        onError("failed to parse response header line: " + lines[i]);
        return false;
      }
      header[m[1]] = m[2];
    }
    if (header["Upgrade"] != "WebSocket") {
      onError("invalid Upgrade: " + header["Upgrade"]);
      return false;
    }
    if (header["Connection"] != "Upgrade") {
      onError("invalid Connection: " + header["Connection"]);
      return false;
    }
    var resOrigin:String = header["Sec-WebSocket-Origin"].toLowerCase();
    if (resOrigin != origin) {
      onError("origin doesn't match: '" + resOrigin + "' != '" + origin + "'");
      return false;
    }
    if (protocol && header["Sec-WebSocket-Protocol"] != protocol) {
      onError("protocol doesn't match: '" +
        header["WebSocket-Protocol"] + "' != '" + protocol + "'");
      return false;
    }
    return true;
  }

  private function makeBufferCompact():void {
    if (buffer.position == 0) return;
    var nextBuffer:ByteArray = new ByteArray();
    buffer.readBytes(nextBuffer);
    buffer = nextBuffer;
  }
  
  private function notifyStateChange():void {
    dispatchEvent(new WebSocketStateEvent("stateChange", readyState, bufferedAmount));
  }
  
  private function initNoiseChars():void {
    noiseChars = new Array();
    for (var i:int = 0x21; i <= 0x2f; ++i) {
      noiseChars.push(String.fromCharCode(i));
    }
    for (var j:int = 0x3a; j <= 0x7a; ++j) {
      noiseChars.push(String.fromCharCode(j));
    }
  }
  
  private function generateKey():String {
    var spaces:uint = randomInt(1, 12);
    var max:uint = uint.MAX_VALUE / spaces;
    var number:uint = randomInt(0, max);
    var key:String = (number * spaces).toString();
    var noises:int = randomInt(1, 12);
    var pos:int;
    for (var i:int = 0; i < noises; ++i) {
      var char:String = noiseChars[randomInt(0, noiseChars.length - 1)];
      pos = randomInt(0, key.length);
      key = key.substr(0, pos) + char + key.substr(pos);
    }
    for (var j:int = 0; j < spaces; ++j) {
      pos = randomInt(1, key.length - 1);
      key = key.substr(0, pos) + " " + key.substr(pos);
    }
    return key;
  }
  
  private function generateKey3():String {
    var key3:String = "";
    for (var i:int = 0; i < 8; ++i) {
      key3 += String.fromCharCode(randomInt(0, 255));
    }
    return key3;
  }
  
  private function getSecurityDigest(key1:String, key2:String, key3:String):String {
    var bytes1:String = keyToBytes(key1);
    var bytes2:String = keyToBytes(key2);
    return MD5.rstr_md5(bytes1 + bytes2 + key3);
  }
  
  private function keyToBytes(key:String):String {
    var keyNum:uint = parseInt(key.replace(/[^\d]/g, ""));
    var spaces:uint = 0;
    for (var i:int = 0; i < key.length; ++i) {
      if (key.charAt(i) == " ") ++spaces;
    }
    var resultNum:uint = keyNum / spaces;
    var bytes:String = "";
    for (var j:int = 3; j >= 0; --j) {
      bytes += String.fromCharCode((resultNum >> (j * 8)) & 0xff);
    }
    return bytes;
  }
  
  private function writeBytes(bytes:String):void {
    for (var i:int = 0; i < bytes.length; ++i) {
      socket.writeByte(bytes.charCodeAt(i));
    }
  }
  
  private function readBytes(buffer:ByteArray, numBytes:int):String {
    var bytes:String = "";
    for (var i:int = 0; i < numBytes; ++i) {
      // & 0xff is to make \x80-\xff positive number.
      bytes += String.fromCharCode(buffer.readByte() & 0xff);
    }
    return bytes;
  }
  
  private function randomInt(min:uint, max:uint):uint {
    return min + Math.floor(Math.random() * (Number(max) - min + 1));
  }

  // for debug
  private function dumpBytes(bytes:String):void {
    var output:String = "";
    for (var i:int = 0; i < bytes.length; ++i) {
      output += bytes.charCodeAt(i).toString() + ", ";
    }
    main.log(output);
  }
  
}

}
