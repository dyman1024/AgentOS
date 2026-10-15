setvbuf(stdout, nil, _IONBF, 0)
import Foundation
import Virtualization

// Minimal VZ Linux boot timer: direct kernel boot + initramfs, virtio console -> pipe.
let args = CommandLine.arguments
let kernel = URL(fileURLWithPath: args[1]); let disk = URL(fileURLWithPath: args[2])
let memMB = UInt64(args.count > 3 ? Int(args[3])! : 512)
let t0 = DispatchTime.now().uptimeNanoseconds
func ms() -> String { String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }

let boot = VZLinuxBootLoader(kernelURL: kernel)
boot.commandLine = "console=hvc0 root=/dev/vda rootfstype=vfat ro init=/init quiet loglevel=0 panic=0 " + (args.count > 4 ? args[4] : "")
let cfg = VZVirtualMachineConfiguration()
cfg.bootLoader = boot
cfg.cpuCount = 2
cfg.memorySize = memMB * 1024 * 1024
let pipe = Pipe()
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
cfg.serialPorts = [serial]
cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try! VZDiskImageStorageDeviceAttachment(url: disk, readOnly: true))]
cfg.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
do { try cfg.validate() } catch { print("validate error: \(error)"); exit(1) }
print("[\(ms()) ms] config validated")

var firstByte = false
var buf = ""
pipe.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData; if d.isEmpty { return }
    if !firstByte { firstByte = true; print("[\(ms()) ms] first console byte") }
    buf += String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
    while let r = buf.range(of: "\n") {
        let line = String(buf[..<r.lowerBound]); buf = String(buf[r.upperBound...])
        if line.contains("AGENTOS") || line.contains("Mem:") || line.contains("anic") || line.contains("rror") { print("[\(ms()) ms] guest: \(line)") }
    }
}

final class D: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { print("[\(ms()) ms] guest stopped"); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError e: Error) { print("[\(ms()) ms] stopped with error \(e)"); exit(2) }
}
let vm = VZVirtualMachine(configuration: cfg)
let del = D(); vm.delegate = del
vm.start { r in
    switch r { case .success: print("[\(ms()) ms] start() completed")
    case .failure(let e): print("start failed: \(e)"); exit(3) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout; partial buffer: \(buf.suffix(2000))"); exit(4) }
dispatchMain()
