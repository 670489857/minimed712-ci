//
//  Minimed712Support.swift
//  MinimedKit
//
//  为美敦力 512/712（含国内 712E）补上 Loop/MinimedKit 缺失的协议分支。
//
//  放置位置：加入 MinimedKit target（Sources/MinimedKit），不要加到 Loop App target，
//  否则访问不到 PumpOpsSession 的 internal 成员。
//
//  依赖以下改动（见 Patches/，01→05 顺序 apply）：
//    1. MessageType 增加 readSettings512 = 0x91
//    2. PumpOpsSession 的 messageSender / wakeup 由 private 改为 internal
//    3. PumpOpsSession.getCurrentPumpStatus() 与 setNormalBolus() 走 512/712 分支
//

import Foundation

// MARK: - 型号判定

public extension PumpModel {

    /// 512 与 712 使用同一套老协议命令（0x91 设置、无 0xCE 状态）。
    var is512or712Family: Bool {
        return self == .model512 || self == .model712
    }

    /// 国内销售的 712E 在泵上仍上报 "712"，靠频率(868MHz/WorldWide)区分。
    var is712EFamilyName: Bool {
        return self == .model712
    }

    var minimedDisplayName: String {
        return self == .model712 ? "712 / 712E" : rawValue
    }

    /// 上游 Loop 是自动识别型号的；如果你们的 fork 有手选列表，直接把这个数组喂给 Picker。
    static var minimedSelectableModels: [PumpModel] {
        return [
            .model512, .model712,
            .model515, .model715,
            .model522, .model722,
            .model523, .model723,
            .model554, .model754
        ]
    }

    /// 512/712 专用子集（设置页/诊断页可以只列这两个）。
    static var minimed512And712Models: [PumpModel] {
        return [.model512, .model712]
    }
}

// MARK: - 0x91 设置读取 / 0xCE 状态替代

public extension PumpOpsSession {

    /// 512/712 专用：读取泵设置（0x91 Configuration），而不是 522+ 的 0xC0。
    func getSettings712() throws -> ReadSettings512CarelinkMessageBody {
        try wakeup()

        return try messageSender.getResponse(
            to: PumpMessage(pumpID: settings.pumpID, type: .readSettings512),
            responseType: .readSettings512,
            repeatCount: 0,
            timeout: MinimedPumpMessageSender.standardPumpResponseWindow,
            retryCount: 3
        )
    }

    /// 型号感知的“泵上限额”回读：512/712 走 0x91，其余走 0xC0。
    /// 用于 MinimedPumpManager.syncDeliveryLimits()。
    func getDeliveryLimits() throws -> (maxBasal: Double, maxBolus: Double) {
        let model = try getPumpModel()

        if model.is512or712Family {
            let settings = try getSettings712()
            return (maxBasal: settings.maxBasal, maxBolus: settings.maxBolus)
        } else {
            let settings = try getSettings()
            return (maxBasal: settings.maxBasal, maxBolus: settings.maxBolus)
        }
    }

    /// 512/712 不支持 0xCE（Pump Status），用 0x72 电量 + 0x73 余量 + 历史事件拼出同等信息。
    /// 比 522+ 的 0xCE 慢（要多跑一条历史页读取），建议沿用 Loop 现有的 5 分钟刷新节奏。
    func getCurrentPumpStatus712() throws -> PumpStatus {
        let model = try getPumpModel()
        let battery = try getBatteryStatus()
        let (reservoir, clock) = try getRemainingInsulin()
        let runState = try getRunState712()

        return PumpStatus(
            clock: clock,
            batteryVolts: Measurement(value: battery.volts, unit: UnitElectricPotentialDifference.volts),
            batteryStatus: battery.status,
            suspended: runState.suspended,
            bolusing: runState.bolusing,
            reservoir: reservoir,
            model: model,
            pumpID: settings.pumpID
        )
    }

    /// 型号感知的运行状态：512/712 从历史推断，其余用 0xCE。
    /// 用于 setNormalBolus() 的“泵是否暂停/正在做大剂量”前置检查。
    func getActiveState(for model: PumpModel) throws -> (suspended: Bool, bolusing: Bool) {
        if model.is512or712Family {
            return try getRunState712()
        } else {
            let status = try getPumpStatus()
            return (suspended: status.suspended, bolusing: status.bolusing)
        }
    }

    /// 从最近 12 小时历史事件推断 512/712 的暂停/大剂量状态。
    ///
    /// 说明：
    /// - 暂停/恢复事件由泵在动作发生时写入历史，可靠；
    /// - 普通大剂量历史是“事后追加”（PumpEvent.isDelayedAppend），
    ///   所以 bolusing 只能作为补充，真正的重叠保护仍依赖 Loop 的 unfinalizedBolus
    ///   以及泵本身对第二条大剂量命令的 commandRefused。
    func getRunState712() throws -> (suspended: Bool, bolusing: Bool) {
        let now = Date()
        let lookback = now.addingTimeInterval(-12 * 60 * 60)
        let (events, _) = try getHistoryEvents(since: lookback)

        var suspended = false
        var lastBolusEvent: BolusNormalPumpEvent?
        var lastBolusDate: Date?

        for event in events {
            switch event.pumpEvent {
            case is SuspendPumpEvent:
                suspended = true
            case is ResumePumpEvent:
                suspended = false
            case let bolus as BolusNormalPumpEvent:
                lastBolusEvent = bolus
                lastBolusDate = event.date
            default:
                break
            }
        }

        var bolusing = false
        if let bolus = lastBolusEvent,
           let date = lastBolusDate,
           bolus.type == .normal {
            bolusing = date.addingTimeInterval(bolus.deliveryTime) > now
        }

        return (suspended: suspended, bolusing: bolusing)
    }
}
