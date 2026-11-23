//
//  ReadSettings512CarelinkMessageBody.swift
//  MinimedKit
//
//  美敦力 512/712（含 712E）专用的 0x91「Configuration / Read Settings」响应解析。
//
//  字段定义来自 decocare ReadSettings512 / AndroidAPS decodeSettings512()。
//  注意：MinimedKit 收到的 body 前面比 decocare 的 data 多 1 个字节，
//  所以这里所有下标都要 +1（可对照同目录的 ReadSettingsCarelinkMessageBody：0xC0 也是同样偏移）。
//
//    [1] 自动关机时间(分钟)          [2] 报警模式/音量(4=静音)
//    [3] 音频大剂量开关              [4] 音频大剂量步进(0.1U)
//    [5] 可变大剂量开关              [6] 最大大剂量(0.1U 刻度)
//    [7..8] 最大基础率(40 刻度/U)    [9] 时间显示(0=12h,1=24h)
//    [10] 胰岛素浓度(0=100,1=50)     [11] 基础率方案开关
//    [12] 当前方案(0=STD,1=A,2=B)    [13] RF 开关
//    [14] 键盘锁开关                 [15] 临时基础率类型(0=U,1=%)
//    [16] 临时基础率百分比           [17] Paradigm Link 开关
//    [18] 胰岛素作用类型(0=Fast,1=Regular)
//    [19] 储药器报警类型(0=U,1=时间) [20] 储药器报警阈值
//    [21] 键盘锁状态
//
//  0x91 的响应长度不固定，这里只要求 >= 22 字节。
//

import Foundation

public enum Minimed712AlarmMode: String, Equatable {
    case silent
    case normal
}

public enum Minimed712TempBasalType: String, Equatable {
    case units
    case percent
}

public enum Minimed712InsulinActionType: String, Equatable {
    case fast
    case regular
}

public enum Minimed712ReservoirWarningType: String, Equatable {
    case time
    case units
}

public class ReadSettings512CarelinkMessageBody: DecodableMessageBody {

    /// 0x91 响应为变长设置块；这里不使用固定长度做校验。
    public static var length: Int = 0

    /// body[0] 是帧前缀，字段从 [1] 开始，最后一个字段在 [21]。
    public static let minimumLength: Int = 22

    /// 512/712 家族：大剂量 10 刻度/U；设置块里的最大基础率按 40 刻度/U 存（decocare / AAPS 同口径）
    public static let bolusStrokesPerUnit: Double = 10
    public static let basalStrokesPerUnit: Double = 40

    public var txData: Data

    public let rawData: Data

    public let autoOffTimeoutMinutes: Int
    public let alarmMode: Minimed712AlarmMode
    public let alarmBeepVolume: Int
    public let audioBolusEnabled: Bool
    public let audioBolusStep: Double?
    public let variableBolusEnabled: Bool
    /// 泵上设置的最大大剂量，单位 U
    public let maxBolus: Double
    /// 泵上设置的最大基础率，单位 U/h
    public let maxBasal: Double
    public let uses24HourClock: Bool
    public let insulinConcentration: Int
    public let basalProfilesEnabled: Bool
    public let activeBasalProfile: BasalProfile
    public let rfEnabled: Bool
    public let keypadBlockEnabled: Bool
    public let tempBasalType: Minimed712TempBasalType
    public let tempBasalPercent: Int?
    public let paradigmLinkEnabled: Bool
    public let insulinActionType: Minimed712InsulinActionType
    public let reservoirWarningType: Minimed712ReservoirWarningType
    public let reservoirWarningPoint: Int
    public let keypadLocked: Bool

    public required init?(rxData: Data) {
        guard rxData.count >= Self.minimumLength else {
            return nil
        }

        self.rawData = rxData
        self.txData = rxData

        autoOffTimeoutMinutes = Int(rxData[1])

        if rxData[2] == 4 {
            alarmMode = .silent
        } else {
            alarmMode = .normal
        }
        alarmBeepVolume = Int(rxData[2])

        audioBolusEnabled = rxData[3] != 0
        audioBolusStep = rxData[3] != 0
            ? Double(rxData[4]) / Self.bolusStrokesPerUnit
            : nil

        variableBolusEnabled = rxData[5] != 0

        maxBolus = Double(rxData[6]) / Self.bolusStrokesPerUnit

        let maxBasalTicks = UInt16(rxData[7]) << 8 | UInt16(rxData[8])
        maxBasal = Double(maxBasalTicks) / Self.basalStrokesPerUnit

        uses24HourClock = rxData[9] != 0
        insulinConcentration = rxData[10] == 0 ? 100 : 50
        basalProfilesEnabled = rxData[11] != 0

        activeBasalProfile = BasalProfile(rawValue: rxData[12])

        rfEnabled = rxData[13] != 0
        keypadBlockEnabled = rxData[14] != 0

        tempBasalType = rxData[15] != 0 ? .percent : .units
        tempBasalPercent = rxData[15] != 0 ? Int(rxData[16]) : nil

        paradigmLinkEnabled = rxData[17] != 0
        insulinActionType = rxData[18] == 0 ? .fast : .regular

        reservoirWarningType = rxData[19] != 0 ? .time : .units
        reservoirWarningPoint = Int(rxData[20])
        keypadLocked = rxData[21] != 0
    }

    public var description: String {
        return "ReadSettings512(maxBasal:\(maxBasal), maxBolus:\(maxBolus), insulinAction:\(insulinActionType.rawValue), reservoirWarning:\(reservoirWarningType.rawValue)@\(reservoirWarningPoint), bytes:\(rawData.count))"
    }
}
