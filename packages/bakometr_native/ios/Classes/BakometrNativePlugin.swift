import AVFoundation
import AudioToolbox
import Flutter
import UIKit
import UserNotifications

public class BakometrNativePlugin: NSObject, FlutterPlugin {
  private var luxMeter: CameraLuxMeter?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "bakometr_native", binaryMessenger: registrar.messenger())
    let instance = BakometrNativePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "startTracking", "updateTracking", "stopTracking":
      // Na iOS działanie w tle zapewnia aktywna sesja nagrywania (UIBackgroundModes: audio).
      result(nil)

    case "canMeasureLuxInBackground":
      result(false)

    case "measureLux":
      guard UIApplication.shared.applicationState == .active else {
        result(nil)
        return
      }
      let meter = CameraLuxMeter()
      luxMeter = meter
      meter.measure { [weak self] lux in
        DispatchQueue.main.async {
          result(lux)
          self?.luxMeter = nil
        }
      }

    case "vibrate":
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
      result(nil)

    case "scheduleNotification":
      let id = args["id"] as? Int ?? 0
      let at = (args["at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
      let daily = args["daily"] as? Bool ?? false
      let content = UNMutableNotificationContent()
      content.title = args["title"] as? String ?? ""
      content.body = args["body"] as? String ?? ""
      content.sound = .default
      let date = Date(timeIntervalSince1970: at / 1000)
      let comps: DateComponents
      if daily {
        comps = Calendar.current.dateComponents([.hour, .minute], from: date)
      } else {
        comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
      }
      let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: daily)
      let req = UNNotificationRequest(identifier: "bakometr_\(id)", content: content, trigger: trigger)
      UNUserNotificationCenter.current().add(req) { _ in }
      result(nil)

    case "cancelNotification":
      let id = args["id"] as? Int ?? 0
      UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["bakometr_\(id)"])
      result(nil)

    case "showAlarm":
      let content = UNMutableNotificationContent()
      content.title = args["title"] as? String ?? "Pobudka!"
      content.body = args["body"] as? String ?? ""
      content.sound = .default
      let req = UNNotificationRequest(identifier: "bakometr_alarm_now", content: content, trigger: nil)
      UNUserNotificationCenter.current().add(req) { _ in }
      result(nil)

    case "cancelAlarm":
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bakometr_alarm_now"])
      result(nil)

    case "requestNotificationPermission":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
      result(nil)

    case "setKeepScreenOn":
      UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// iPhone nie udostępnia czujnika światła otoczenia, więc szacujemy luksy z
/// parametrów automatycznej ekspozycji przedniej kamery (telefon ekranem do góry).
/// EV100 = log2(N²/t) − log2(ISO/100);  E ≈ 2.5 · 2^EV100 [lx]
final class CameraLuxMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "bakometr.lux")
  private var finished = false

  func measure(_ done: @escaping (Double?) -> Void) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted { self.run(done) } else { done(nil) }
      }
      return
    }
    guard status == .authorized else { done(nil); return }
    run(done)
  }

  private func run(_ done: @escaping (Double?) -> Void) {
    queue.async {
      guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
              ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device) else {
        done(nil)
        return
      }
      self.session.beginConfiguration()
      self.session.sessionPreset = .low
      if self.session.canAddInput(input) { self.session.addInput(input) }
      let output = AVCaptureVideoDataOutput()
      output.setSampleBufferDelegate(self, queue: self.queue)
      if self.session.canAddOutput(output) { self.session.addOutput(output) }
      self.session.commitConfiguration()
      self.session.startRunning()

      // Dajemy automatyce ekspozycji 2 s na ustabilizowanie się.
      self.queue.asyncAfter(deadline: .now() + 2.0) {
        let t = CMTimeGetSeconds(device.exposureDuration)
        let iso = Double(device.iso)
        let n = Double(device.lensAperture)
        self.session.stopRunning()
        guard t > 0, iso > 0, n > 0 else { done(nil); return }
        let ev100 = log2(n * n / t) - log2(iso / 100.0)
        let lux = 2.5 * pow(2.0, ev100)
        done(max(0, lux))
      }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    // Klatki nie są potrzebne — wystarczają parametry ekspozycji.
  }
}
