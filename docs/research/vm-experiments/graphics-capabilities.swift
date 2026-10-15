import Foundation
import Virtualization
func check(_ name: String, _ f: (VZVirtualMachineConfiguration) -> Void) {
  let cfg = VZVirtualMachineConfiguration()
  let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: "/Applications/Docker.app/Contents/Resources/linuxkit/kernel"))
  cfg.bootLoader = boot; cfg.cpuCount = 2; cfg.memorySize = 512*1024*1024
  f(cfg)
  do { try cfg.validate(); try cfg.validateSaveRestoreSupport(); print("\(name): save/restore SUPPORTED") }
  catch { print("\(name): \(error.localizedDescription)") }
}
check("virtio-gpu") { c in let g = VZVirtioGraphicsDeviceConfiguration(); g.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]; c.graphicsDevices = [g] }
check("virtiofs share") { c in let fs = VZVirtioFileSystemDeviceConfiguration(tag: "share"); fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: "/tmp"), readOnly: true)); c.directorySharingDevices = [fs] }
check("NAT network") { c in let n = VZVirtioNetworkDeviceConfiguration(); n.attachment = VZNATNetworkDeviceAttachment(); c.networkDevices = [n] }
check("vsock") { c in c.socketDevices = [VZVirtioSocketDeviceConfiguration()] }
check("keyboard+pointer") { c in c.keyboards = [VZUSBKeyboardConfiguration()]; c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()] }
check("rosetta") { c in if let r = try? VZLinuxRosettaDirectoryShare() { let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta"); fs.share = r; c.directorySharingDevices = [fs] } ; print("  rosetta availability: \(VZLinuxRosettaDirectoryShare.availability.rawValue)") }
