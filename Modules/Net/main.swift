//
//  main.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 24/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SystemConfiguration
import WidgetKit

public enum Network_t: String, Codable {
    case wifi
    case ethernet
    case bluetooth
    case other
}

public struct Network_interface: Codable {
    var displayName: String = ""
    var BSDName: String = ""
    var address: String = ""
}

public struct Network_addr: Codable {
    var v4: String? = nil
    var v6: String? = nil
    var countryCode: String? = nil
}

public struct Network_wifi: Codable {
    var countryCode: String? = nil
    var ssid: String? = nil
    var bssid: String? = nil
    var RSSI: Int? = nil
    var noise: Int? = nil
    var transmitRate: Double? = nil
    
    var standard: String? = nil
    var mode: String? = nil
    var security: String? = nil
    var channel: String? = nil
    
    var channelBand: String? = nil
    var channelWidth: String? = nil
    var channelNumber: String? = nil
    
    mutating func reset() {
        self.countryCode = nil
        self.ssid = nil
        self.RSSI = nil
        self.noise = nil
        self.transmitRate = nil
        self.standard = nil
        self.mode = nil
        self.security = nil
        self.channel = nil
    }
}

public struct Bandwidth: Codable {
    var upload: Int64 = 0
    var download: Int64 = 0
}

public struct Network_Usage: Codable, RemoteType {
    var bandwidth: Bandwidth = Bandwidth()
    var total: Bandwidth = Bandwidth()
    
    var laddr: Network_addr = Network_addr() // local ip
    var raddr: Network_addr = Network_addr() // remote ip
    
    var interface: Network_interface? = nil
    var connectionType: Network_t? = nil
    var status: Bool = false
    
    var wifiDetails: Network_wifi = Network_wifi()
    
    mutating func reset() {
        self.bandwidth = Bandwidth()
        
        self.laddr = Network_addr()
        self.raddr = Network_addr()
        
        self.interface = nil
        self.connectionType = nil
        
        self.wifiDetails.reset()
    }
    
    public func remote() -> Data? {
        let addr = "\(self.laddr.v4 ?? ""),\(self.laddr.v6 ?? ""),\(self.raddr.v4 ?? ""),\(self.raddr.v6 ?? "")"
        let string = "1,\(self.interface?.BSDName ?? ""),1,\(self.bandwidth.download),\(self.bandwidth.upload),\(addr)$"
        return string.data(using: .utf8)
    }
}

public struct Network_Connectivity: Codable {
    var status: Bool = false
    var latency: Double = 0
}

public struct Network_Process: Codable, Process_p {
    public var pid: Int
    public var name: String
    public var time: Date
    public var download: Int
    public var upload: Int
    public var icon: NSImage {
        get {
            if let app = NSRunningApplication(processIdentifier: pid_t(self.pid)), let icon = app.icon {
                return icon
            }
            return Constants.defaultProcessIcon
        }
    }
    
    public init(pid: Int = 0, name: String = "", time: Date = Date(), download: Int = 0, upload: Int = 0) {
        self.pid = pid
        self.name = name
        self.time = time
        self.download = download
        self.upload = upload
    }
}

public class Network: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var usageReader: UsageReader? = nil
    private var processReader: ProcessReader? = nil
    private var connectivityReader: ConnectivityReader? = nil
    
    private let ipUpdater = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.Network.IP")
    private let usageReseter = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.Network.Usage")
    
    private var widgetActivationThresholdState: Bool {
        Store.shared.bool(key: "\(self.config.name)_widgetActivationThresholdState", defaultValue: false)
    }
    private var widgetActivationThreshold: Int {
        Store.shared.int(key: "\(self.config.name)_widgetActivationThreshold", defaultValue: 0)
    }
    private var widgetActivationThresholdSize: SizeUnit {
        SizeUnit.fromString(Store.shared.string(key: "\(self.name)_widgetActivationThresholdSize", defaultValue: SizeUnit.MB.key))
    }
    private var publicIPRefreshInterval: String {
        Store.shared.string(key: "\(self.name)_publicIPRefreshInterval", defaultValue: "never")
    }
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$addr.public - $status")
    }
    
    public init() {
        self.settingsView = Settings(.network)
        self.popupView = Popup(.network)
        self.portalView = Portal(.network)
        self.notificationsView = Notifications(.network)
        
        super.init(
            moduleType: .network,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.usageReader = UsageReader(.network) { [weak self] value in
            self?.usageCallback(value)
        }
        self.processReader = ProcessReader(.network) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        self.connectivityReader = ConnectivityReader(.network) { [weak self] value in
            self?.connectivityCallback(value)
        }
        
        self.settingsView.callbackWhenUpdateNumberOfProcesses = {
            self.popupView.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async {
                self.processReader?.read()
            }
        }
        
        self.settingsView.callback = { [weak self] in
            self?.usageReader?.getDetails()
            self?.usageReader?.read()
        }
        self.settingsView.usageResetCallback = { [weak self] in
            self?.setUsageReset()
        }
        self.settingsView.ICMPHostCallback = { [weak self] isDisabled in
            if isDisabled {
                self?.popupView.resetConnectivityView()
                self?.connectivityCallback(Network_Connectivity(status: false))
            }
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.connectivityReader?.setInterval(value)
        }
        self.settingsView.publicIPRefreshIntervalCallback = { [weak self] in
            self?.setIPUpdater()
        }
        
        self.setReaders([self.usageReader, self.processReader, self.connectivityReader])
        
        self.setIPUpdater()
        self.setUsageReset()
    }
    
    public override func isAvailable() -> Bool {
        var list: [String] = []
        for interface in SCNetworkInterfaceCopyAll() as NSArray {
            if let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface as! SCNetworkInterface) {
                list.append(displayName as String)
            }
        }
        return !list.isEmpty
    }
    
    private func usageCallback(_ raw: Network_Usage?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.usageCallback(value)
        self.portalView.usageCallback(value)
        self.notificationsView.usageCallback(value)
        
        var upload: Int64 = value.bandwidth.upload
        var download: Int64 = value.bandwidth.download
        if self.widgetActivationThresholdState {
            upload = 0
            download = 0
            let threshold = self.widgetActivationThresholdSize.toBytes(self.widgetActivationThreshold)
            if value.bandwidth.upload >= threshold || value.bandwidth.download >= threshold {
                upload = value.bandwidth.upload
                download = value.bandwidth.download
            }
        }
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as SpeedWidget: widget.setValue(input: download, output: upload)
            case let widget as NetworkChart: widget.setValue(upload: Double(upload), download: Double(download))
            case let widget as TextWidget:
                var text = self.textValue
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$addr":
                        switch pair.value {
                        case "public": replacement = value.raddr.v4 ?? value.raddr.v6 ?? "-"
                        case "publicV4": replacement = value.raddr.v4 ?? "-"
                        case "publicV6": replacement = value.raddr.v6 ?? "-"
                        case "private": replacement = value.laddr.v4 ?? value.laddr.v6 ?? "-"
                        case "privateV4": replacement = value.laddr.v4 ?? "-"
                        case "privateV6": replacement = value.laddr.v6 ?? "-"
                        default: return
                        }
                    case "$interface":
                        switch pair.value {
                        case "displayName": replacement = value.interface?.displayName ?? "-"
                        case "BSDName": replacement = value.interface?.BSDName ?? "-"
                        case "address": replacement = value.interface?.address ?? "-"
                        default: return
                        }
                    case "$wifi":
                        switch pair.value {
                        case "ssid": replacement = value.wifiDetails.ssid ?? "-"
                        case "bssid": replacement = value.wifiDetails.bssid ?? "-"
                        case "RSSI": replacement = "\(value.wifiDetails.RSSI ?? 0)"
                        case "noise": replacement = "\(value.wifiDetails.noise ?? 0)"
                        case "transmitRate": replacement = "\(value.wifiDetails.transmitRate ?? 0)"
                        case "standard": replacement = value.wifiDetails.standard ?? "-"
                        case "mode": replacement = value.wifiDetails.mode ?? "-"
                        case "security": replacement = value.wifiDetails.security ?? "-"
                        case "channel": replacement = value.wifiDetails.channel ?? "-"
                        case "channelBand": replacement = value.wifiDetails.channelBand ?? "-"
                        case "channelWidth": replacement = value.wifiDetails.channelWidth ?? "-"
                        case "channelNumber": replacement = value.wifiDetails.channelNumber ?? "-"
                        default: return
                        }
                    case "$status":
                        replacement = localizedString(value.status ? "UP" : "DOWN")
                    case "$upload":
                        switch pair.value {
                        case "total": replacement = Units(bytes: value.total.upload).getReadableMemory()
                        default: replacement = Units(bytes: value.bandwidth.upload).getReadableMemory()
                        }
                    case "$download":
                        switch pair.value {
                        case "total": replacement = Units(bytes: value.total.download).getReadableMemory()
                        default: replacement = Units(bytes: value.bandwidth.download).getReadableMemory()
                        }
                    case "$type":
                        replacement = value.connectionType?.rawValue ?? "-"
                    case "$icmp":
                        guard let connectivity = self.connectivityReader?.value else { return }
                        switch pair.value {
                        case "status": replacement = localizedString(connectivity.status ? "UP" : "DOWN")
                        case "latency": replacement = "\(Int(connectivity.latency)) ms"
                        default: return
                        }
                    default: return
                    }
                    
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            default: break
            }
        }
        
        if #available(macOS 11.0, *) {
            guard let blobData = try? JSONEncoder().encode(raw) else { return }
            self.userDefaults?.set(blobData, forKey: "Network@UsageReader")
            WidgetCenter.shared.reloadTimelines(ofKind: Network_entry.kind)
        }
    }
    
    private func connectivityCallback(_ raw: Network_Connectivity?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.connectivityCallback(value)
        self.notificationsView.connectivityCallback(value)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as StateWidget: widget.setValue(value.status)
            default: break
            }
        }
    }
    
    private func setIPUpdater() {
        self.ipUpdater.invalidate()
        
        switch self.publicIPRefreshInterval {
        case "hour":
            self.ipUpdater.interval = 60 * 60
        case "12":
            self.ipUpdater.interval = 60 * 60 * 12
        case "24":
            self.ipUpdater.interval = 60 * 60 * 24
        default: return
        }
        
        self.ipUpdater.repeats = true
        self.ipUpdater.schedule { (completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) in
            guard self.enabled && self.isAvailable() else { return }
            debug("going to automatically refresh IP address...")
            NotificationCenter.default.post(name: .refreshPublicIP, object: nil, userInfo: nil)
            completion(NSBackgroundActivityScheduler.Result.finished)
        }
    }
    
    private func setUsageReset() {
        self.usageReseter.invalidate()
        
        switch AppUpdateInterval(rawValue: Store.shared.string(key: "\(self.config.name)_usageReset", defaultValue: AppUpdateInterval.never.rawValue)) {
        case .oncePerDay: self.usageReseter.interval = 60 * 60 * 24
        case .oncePerWeek: self.usageReseter.interval = 60 * 60 * 24 * 7
        case .oncePerMonth: self.usageReseter.interval = 60 * 60 * 24 * 30
        case .atStart: NotificationCenter.default.post(name: .resetTotalNetworkUsage, object: nil, userInfo: nil)
        case .never: return
        default: return
        }
        
        self.usageReseter.repeats = true
        self.usageReseter.schedule { (completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) in
            guard self.enabled && self.isAvailable() else {
                return
            }
            
            debug("going to reset the usage...")
            NotificationCenter.default.post(name: .resetTotalNetworkUsage, object: nil, userInfo: nil)
            completion(NSBackgroundActivityScheduler.Result.finished)
        }
    }
}
