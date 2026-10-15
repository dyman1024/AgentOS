setvbuf(stdout, nil, _IONBF, 0)
import Foundation
import Virtualization
// usage: snap <kernel> <disk> <memMB> save|restore <statefile> <midfile>
let a = CommandLine.arguments
let memMB = UInt64(Int(a[3])!); let mode = a[4]; let state = URL(fileURLWithPath: a[5]); let midURL = URL(fileURLWithPath: a[6])
let t0 = DispatchTime.now().uptimeNanoseconds
func ms() -> String { String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: a[1]))
boot.commandLine = "console=hvc0 root=/dev/vda rootfstype=vfat ro init=/init quiet loglevel=0 panic=0 agentos.sleep"
let cfg = VZVirtualMachineConfiguration()
cfg.bootLoader = boot; cfg.cpuCount = 2; cfg.memorySize = memMB * 1024 * 1024
let plat = VZGenericPlatformConfiguration()
if mode == "restore", let d = try? Data(contentsOf: midURL), let mid = VZGenericMachineIdentifier(dataRepresentation: d) { plat.machineIdentifier = mid }
else { try! plat.machineIdentifier.dataRepresentation.write(to: midURL) }
cfg.platform = plat
let pipe = Pipe()
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
cfg.serialPorts = [serial]
cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try! VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: a[2]), readOnly: true))]
try! cfg.validate()
try! cfg.validateSaveRestoreSupport()
pipe.fileHandleForReading.readabilityHandler = { h in
  let s = String(decoding: h.availableData, as: UTF8.self)
  if s.contains("AGENTOS") { print("[\(ms()) ms] guest userspace up") }
}
final class D: NSObject, VZVirtualMachineDelegate {
  func guestDidStop(_ vm: VZVirtualMachine) { print("[\(ms()) ms] guest stopped"); exit(0) }
}
let vm = VZVirtualMachine(configuration: cfg); let del = D(); vm.delegate = del
if mode == "save" {
  vm.start { _ in
    print("[\(ms()) ms] started")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      // touch: just pause + save
      vm.pause { _ in
        let ts = DispatchTime.now().uptimeNanoseconds
        vm.saveMachineStateTo(url: state) { err in
          let d = Double(DispatchTime.now().uptimeNanoseconds - ts)/1e6
          let sz = (try? FileManager.default.attributesOfItem(atPath: state.path)[.size] as? Int) ?? -1
          print("save: err=\(String(describing: err)) took \(String(format: "%.1f", d)) ms, file \(sz/1024/1024) MB")
          exit(0)
        }
      }
    }
  }
} else {
  vm.restoreMachineStateFrom(url: state) { err in
    print("[\(ms()) ms] restored err=\(String(describing: err))")
    vm.resume { r in print("[\(ms()) ms] resumed \(r)"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { print("[\(ms()) ms] alive state=\(vm.state.rawValue)"); exit(0) } }
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("timeout"); exit(4) }
dispatchMain()
