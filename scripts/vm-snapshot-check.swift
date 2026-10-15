import AppKit
import Foundation
import Virtualization

@MainActor func probe() async throws {
  let args=CommandLine.arguments
  guard args.count>=3 else{throw NSError(domain:"arguments",code:1)}
  let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("agentos-vz-probe-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let machineID=VZGenericMachineIdentifier()
  func make() throws -> VZVirtualMachine {
    let c=VZVirtualMachineConfiguration(),b=VZLinuxBootLoader(kernelURL:URL(fileURLWithPath:args[1]))
    b.commandLine="console=hvc0 root=/dev/vda rootfstype=ext4 ro init=/bin/sleep quiet 1000"
    c.bootLoader=b;c.cpuCount=2;c.memorySize=512*1024*1024
    let platform=VZGenericPlatformConfiguration();platform.machineIdentifier=machineID;c.platform=platform
    c.entropyDevices=[VZVirtioEntropyDeviceConfiguration()]
    c.storageDevices=[VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:URL(fileURLWithPath:args[2]),readOnly:true))]
    if args.contains("--vsock"){c.socketDevices=[VZVirtioSocketDeviceConfiguration()]}
    try c.validate();try c.validateSaveRestoreSupport()
    return VZVirtualMachine(configuration:c)
  }
  var vm:VZVirtualMachine?=try make()
  try await vm!.start();try await Task.sleep(for:.seconds(2));try await vm!.pause()
  let file=root.appendingPathComponent("state.vzvmsave")
  try await vm!.saveMachineStateTo(url:file);try await vm!.stop();vm=nil
  vm=try make();try await vm!.restoreMachineStateFrom(url:file);try await vm!.resume();try await vm!.stop()
  print("PASS: minimal snapshot; vsock=\(args.contains("--vsock"))")
}
MainActor.assumeIsolated {
 let app=NSApplication.shared;app.setActivationPolicy(.accessory)
 Task{@MainActor in do{try await probe();exit(0)}catch{print("FAIL: \(error)");exit(1)}}
 app.run()
}
