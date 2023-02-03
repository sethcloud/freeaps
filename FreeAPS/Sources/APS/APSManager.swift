import Combine
import Foundation
import LoopKit
import LoopKitUI
import OmniBLE
import OmniKit
import RileyLinkKit
import SwiftDate
import Swinject

protocol APSManager {
    func heartbeat(date: Date)
    func autotune() -> AnyPublisher<Autotune?, Never>
    func enactBolus(amount: Double, isSMB: Bool)
    var pumpManager: PumpManagerUI? { get set }
    var bluetoothManager: BluetoothStateManager? { get }
    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> { get }
    var pumpName: CurrentValueSubject<String, Never> { get }
    var isLooping: CurrentValueSubject<Bool, Never> { get }
    var lastLoopDate: Date { get }
    var lastLoopDateSubject: PassthroughSubject<Date, Never> { get }
    var bolusProgress: CurrentValueSubject<Decimal?, Never> { get }
    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> { get }
    var isManualTempBasal: Bool { get }
    func enactTempBasal(rate: Double, duration: TimeInterval)
    func makeProfiles() -> AnyPublisher<Bool, Never>
    func determineBasal() -> AnyPublisher<Bool, Never>
    func determineBasalSync()
    func roundBolus(amount: Decimal) -> Decimal
    var lastError: CurrentValueSubject<Error?, Never> { get }
    func cancelBolus()
    func enactAnnouncement(_ announcement: Announcement)
}

enum APSError: LocalizedError {
    case pumpError(Error)
    case invalidPumpState(message: String)
    case glucoseError(message: String)
    case apsError(message: String)
    case deviceSyncError(message: String)
    case manualBasalTemp(message: String)

    var errorDescription: String? {
        switch self {
        case let .pumpError(error):
            return "Pump error: \(error.localizedDescription)"
        case let .invalidPumpState(message):
            return "Error: Invalid Pump State: \(message)"
        case let .glucoseError(message):
            return "Error: Invalid glucose: \(message)"
        case let .apsError(message):
            return "APS error: \(message)"
        case let .deviceSyncError(message):
            return "Sync error: \(message)"
        case let .manualBasalTemp(message):
            return "Manual Basal Temp : \(message)"
        }
    }
}

final class BaseAPSManager: APSManager, Injectable {
    private let processQueue = DispatchQueue(label: "BaseAPSManager.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var alertHistoryStorage: AlertHistoryStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var announcementsStorage: AnnouncementsStorage!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var nightscout: NightscoutManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Persisted(key: "lastAutotuneDate") private var lastAutotuneDate = Date()
    @Persisted(key: "lastLoopDate") var lastLoopDate: Date = .distantPast {
        didSet {
            lastLoopDateSubject.send(lastLoopDate)
        }
    }

    private var openAPS: OpenAPS!

    private var lifetime = Lifetime()

    var pumpManager: PumpManagerUI? {
        get { deviceDataManager.pumpManager }
        set { deviceDataManager.pumpManager = newValue }
    }

    var bluetoothManager: BluetoothStateManager? { deviceDataManager.bluetoothManager }

    @Persisted(key: "isManualTempBasal") var isManualTempBasal: Bool = false

    let isLooping = CurrentValueSubject<Bool, Never>(false)
    let lastLoopDateSubject = PassthroughSubject<Date, Never>()
    let lastError = CurrentValueSubject<Error?, Never>(nil)

    let bolusProgress = CurrentValueSubject<Decimal?, Never>(nil)

    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> {
        deviceDataManager.pumpDisplayState
    }

    var pumpName: CurrentValueSubject<String, Never> {
        deviceDataManager.pumpName
    }

    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> {
        deviceDataManager.pumpExpiresAtDate
    }

    var settings: FreeAPSSettings {
        get { settingsManager.settings }
        set { settingsManager.settings = newValue }
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage)
        subscribe()
        lastLoopDateSubject.send(lastLoopDate)

        isLooping
            .weakAssign(to: \.deviceDataManager.loopInProgress, on: self)
            .store(in: &lifetime)
    }

    private func subscribe() {
        deviceDataManager.recommendsLoop
            .receive(on: processQueue)
            .sink { [weak self] in
                self?.loop()
            }
            .store(in: &lifetime)
        pumpManager?.addStatusObserver(self, queue: processQueue)

        deviceDataManager.errorSubject
            .receive(on: processQueue)
            .map { APSError.pumpError($0) }
            .sink {
                self.processError($0)
            }
            .store(in: &lifetime)

        deviceDataManager.bolusTrigger
            .receive(on: processQueue)
            .sink { bolusing in
                if bolusing {
                    self.createBolusReporter()
                } else {
                    self.clearBolusReporter()
                }
            }
            .store(in: &lifetime)

        // manage a manual Temp Basal from OmniPod - Force loop() after stop a temp basal or finished
        deviceDataManager.manualTempBasal
            .receive(on: processQueue)
            .sink { manualBasal in
                if manualBasal {
                    self.isManualTempBasal = true
                } else {
                    if self.isManualTempBasal {
                        self.isManualTempBasal = false
                        self.loop()
                    }
                }
            }
            .store(in: &lifetime)
    }

    func heartbeat(date: Date) {
        deviceDataManager.heartbeat(date: date)
    }

    // Loop entry point
    private func loop() {
        guard !isLooping.value else {
            warning(.apsManager, "Already looping, skip")
            return
        }

        debug(.apsManager, "Starting loop")

        var loopStatRecord = LoopStats(
            start: Date(),
            loopStatus: "Starting"
        )

        isLooping.send(true)
        determineBasal()
            .replaceEmpty(with: false)
            .flatMap { [weak self] success -> AnyPublisher<Void, Error> in
                guard let self = self, success else {
                    return Fail(error: APSError.apsError(message: "Determine basal failed")).eraseToAnyPublisher()
                }

                // Open loop completed
                guard self.settings.closedLoop else {
                    self.nightscout.uploadStatus()
                    return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
                }

                self.nightscout.uploadStatus()

                // Closed loop - enact suggested
                return self.enactSuggested()
            }
            .sink { [weak self] completion in
                guard let self = self else { return }
                loopStatRecord.end = Date()
                loopStatRecord.duration = self.roundDouble(
                    (loopStatRecord.end! - loopStatRecord.start).timeInterval / 60,
                    2
                )
                if case let .failure(error) = completion {
                    loopStatRecord.loopStatus = error.localizedDescription
                    self.loopCompleted(error: error, loopStatRecord: loopStatRecord)
                } else {
                    loopStatRecord.loopStatus = "Success"
                    self.loopCompleted(loopStatRecord: loopStatRecord)
                }
            } receiveValue: {}
            .store(in: &lifetime)
    }

    // Loop exit point
    private func loopCompleted(error: Error? = nil, loopStatRecord: LoopStats) {
        isLooping.send(false)

        if let error = error {
            warning(.apsManager, "Loop failed with error: \(error.localizedDescription)")
            processError(error)
        } else {
            debug(.apsManager, "Loop succeeded")
            lastLoopDate = Date()
            lastError.send(nil)
        }

        loopStats(loopStatRecord: loopStatRecord)

        // Create a statistics.json
        if settings.displayStatistics {
            statistics()
        }

        if settings.closedLoop {
            reportEnacted(received: error == nil)
        }
    }

    private func verifyStatus() -> Error? {
        guard let pump = pumpManager else {
            return APSError.invalidPumpState(message: "Pump not set")
        }
        let status = pump.status.pumpStatus

        guard !status.bolusing else {
            return APSError.invalidPumpState(message: "Pump is bolusing")
        }

        guard !status.suspended else {
            return APSError.invalidPumpState(message: "Pump suspended")
        }

        let reservoir = storage.retrieve(OpenAPS.Monitor.reservoir, as: Decimal.self) ?? 100
        guard reservoir >= 0 else {
            return APSError.invalidPumpState(message: "Reservoir is empty")
        }

        return nil
    }

    private func autosens() -> AnyPublisher<Bool, Never> {
        guard let autosens = storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self),
              (autosens.timestamp ?? .distantPast).addingTimeInterval(30.minutes.timeInterval) > Date()
        else {
            return openAPS.autosense()
                .map { $0 != nil }
                .eraseToAnyPublisher()
        }

        return Just(false).eraseToAnyPublisher()
    }

    func determineBasal() -> AnyPublisher<Bool, Never> {
        debug(.apsManager, "Start determine basal")
        guard let glucose = storage.retrieve(OpenAPS.Monitor.glucose, as: [BloodGlucose].self), glucose.isNotEmpty else {
            debug(.apsManager, "Not enough glucose data")
            processError(APSError.glucoseError(message: "Not enough glucose data"))
            return Just(false).eraseToAnyPublisher()
        }

        let lastGlucoseDate = glucoseStorage.lastGlucoseDate()
        guard lastGlucoseDate >= Date().addingTimeInterval(-12.minutes.timeInterval) else {
            debug(.apsManager, "Glucose data is stale")
            processError(APSError.glucoseError(message: "Glucose data is stale"))
            return Just(false).eraseToAnyPublisher()
        }

        guard glucoseStorage.isGlucoseNotFlat() else {
            debug(.apsManager, "Glucose data is too flat")
            processError(APSError.glucoseError(message: "Glucose data is too flat"))
            return Just(false).eraseToAnyPublisher()
        }

        let now = Date()
        let temp = currentTemp(date: now)

        let mainPublisher = makeProfiles()
            .flatMap { _ in self.autosens() }
            .flatMap { _ in self.dailyAutotune() }
            .flatMap { _ in self.openAPS.determineBasal(currentTemp: temp, clock: now) }
            .map { suggestion -> Bool in
                if let suggestion = suggestion {
                    DispatchQueue.main.async {
                        self.broadcaster.notify(SuggestionObserver.self, on: .main) {
                            $0.suggestionDidUpdate(suggestion)
                        }
                    }
                }

                return suggestion != nil
            }
            .eraseToAnyPublisher()

        if temp.duration == 0,
           settings.closedLoop,
           settingsManager.preferences.unsuspendIfNoTemp,
           let pump = pumpManager,
           pump.status.pumpStatus.suspended
        {
            return pump.resumeDelivery()
                .flatMap { _ in mainPublisher }
                .replaceError(with: false)
                .eraseToAnyPublisher()
        }

        return mainPublisher
    }

    func determineBasalSync() {
        determineBasal().cancellable().store(in: &lifetime)
    }

    func makeProfiles() -> AnyPublisher<Bool, Never> {
        openAPS.makeProfiles(useAutotune: settings.useAutotune)
            .map { tunedProfile in
                if let basalProfile = tunedProfile?.basalProfile {
                    self.processQueue.async {
                        self.broadcaster.notify(BasalProfileObserver.self, on: self.processQueue) {
                            $0.basalProfileDidChange(basalProfile)
                        }
                    }
                }

                return tunedProfile != nil
            }
            .eraseToAnyPublisher()
    }

    func roundBolus(amount: Decimal) -> Decimal {
        guard let pump = pumpManager else { return amount }
        let rounded = Decimal(pump.roundToSupportedBolusVolume(units: Double(amount)))
        let maxBolus = Decimal(pump.roundToSupportedBolusVolume(units: Double(settingsManager.pumpSettings.maxBolus)))
        return min(rounded, maxBolus)
    }

    private var bolusReporter: DoseProgressReporter?

    func enactBolus(amount: Double, isSMB: Bool) {
        if let error = verifyStatus() {
            processError(error)
            processQueue.async {
                self.broadcaster.notify(BolusFailureObserver.self, on: self.processQueue) {
                    $0.bolusDidFail()
                }
            }
            return
        }

        guard let pump = pumpManager else { return }

        let roundedAmout = pump.roundToSupportedBolusVolume(units: amount)

        debug(.apsManager, "Enact bolus \(roundedAmout), manual \(!isSMB)")

        pump.enactBolus(units: roundedAmout, automatic: isSMB).sink { completion in
            if case let .failure(error) = completion {
                warning(.apsManager, "Bolus failed with error: \(error.localizedDescription)")
                self.processError(APSError.pumpError(error))
                if !isSMB {
                    self.processQueue.async {
                        self.broadcaster.notify(BolusFailureObserver.self, on: self.processQueue) {
                            $0.bolusDidFail()
                        }
                    }
                }
            } else {
                debug(.apsManager, "Bolus succeeded")
                if !isSMB {
                    self.determineBasal().sink { _ in }.store(in: &self.lifetime)
                }
                self.bolusProgress.send(0)
            }
        } receiveValue: { _ in }
            .store(in: &lifetime)
    }

    func cancelBolus() {
        guard let pump = pumpManager, pump.status.pumpStatus.bolusing else { return }
        debug(.apsManager, "Cancel bolus")
        pump.cancelBolus().sink { completion in
            if case let .failure(error) = completion {
                debug(.apsManager, "Bolus cancellation failed with error: \(error.localizedDescription)")
                self.processError(APSError.pumpError(error))
            } else {
                debug(.apsManager, "Bolus cancelled")
            }

            self.bolusReporter?.removeObserver(self)
            self.bolusReporter = nil
            self.bolusProgress.send(nil)
        } receiveValue: { _ in }
            .store(in: &lifetime)
    }

    func enactTempBasal(rate: Double, duration: TimeInterval) {
        if let error = verifyStatus() {
            processError(error)
            return
        }

        guard let pump = pumpManager else { return }

        // unable to do temp basal during manual temp basal 😁
        if isManualTempBasal {
            processError(APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp"))
            return
        }

        debug(.apsManager, "Enact temp basal \(rate) - \(duration)")

        let roundedAmout = pump.roundToSupportedBasalRate(unitsPerHour: rate)
        pump.enactTempBasal(unitsPerHour: roundedAmout, for: duration) { error in
            if let error = error {
                debug(.apsManager, "Temp Basal failed with error: \(error.localizedDescription)")
                self.processError(APSError.pumpError(error))
            } else {
                debug(.apsManager, "Temp Basal succeeded")
                let temp = TempBasal(duration: Int(duration / 60), rate: Decimal(rate), temp: .absolute, timestamp: Date())
                self.storage.save(temp, as: OpenAPS.Monitor.tempBasal)
                if rate == 0, duration == 0 {
                    self.pumpHistoryStorage.saveCancelTempEvents()
                }
            }
        }
    }

    func dailyAutotune() -> AnyPublisher<Bool, Never> {
        guard settings.useAutotune else {
            return Just(false).eraseToAnyPublisher()
        }

        let now = Date()

        guard lastAutotuneDate.isBeforeDate(now, granularity: .day) else {
            return Just(false).eraseToAnyPublisher()
        }
        lastAutotuneDate = now

        return autotune().map { $0 != nil }.eraseToAnyPublisher()
    }

    func autotune() -> AnyPublisher<Autotune?, Never> {
        openAPS.autotune().eraseToAnyPublisher()
    }

    func enactAnnouncement(_ announcement: Announcement) {
        guard let action = announcement.action else {
            warning(.apsManager, "Invalid Announcement action")
            return
        }

        guard let pump = pumpManager else {
            warning(.apsManager, "Pump is not set")
            return
        }

        debug(.apsManager, "Start enact announcement: \(action)")

        switch action {
        case let .bolus(amount):
            if let error = verifyStatus() {
                processError(error)
                return
            }
            let roundedAmount = pump.roundToSupportedBolusVolume(units: Double(amount))
            pump.enactBolus(units: roundedAmount, activationType: .manualRecommendationAccepted) { error in
                if let error = error {
                    // warning(.apsManager, "Announcement Bolus failed with error: \(error.localizedDescription)")
                    switch error {
                    case .uncertainDelivery:
                        // Do not generate notification on uncertain delivery error
                        break
                    default:
                        // Do not generate notifications for automatic boluses that fail.
                        warning(.apsManager, "Announcement Bolus failed with error: \(error.localizedDescription)")
                    }

                } else {
                    debug(.apsManager, "Announcement Bolus succeeded")
                    self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                    self.bolusProgress.send(0)
                }
            }
        case let .pump(pumpAction):
            switch pumpAction {
            case .suspend:
                if let error = verifyStatus() {
                    processError(error)
                    return
                }
                pump.suspendDelivery { error in
                    if let error = error {
                        debug(.apsManager, "Pump not suspended by Announcement: \(error.localizedDescription)")
                    } else {
                        debug(.apsManager, "Pump suspended by Announcement")
                        self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                        self.nightscout.uploadStatus()
                    }
                }
            case .resume:
                guard pump.status.pumpStatus.suspended else {
                    return
                }
                pump.resumeDelivery { error in
                    if let error = error {
                        warning(.apsManager, "Pump not resumed by Announcement: \(error.localizedDescription)")
                    } else {
                        debug(.apsManager, "Pump resumed by Announcement")
                        self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                        self.nightscout.uploadStatus()
                    }
                }
            }
        case let .looping(closedLoop):
            settings.closedLoop = closedLoop
            debug(.apsManager, "Closed loop \(closedLoop) by Announcement")
            announcementsStorage.storeAnnouncements([announcement], enacted: true)
        case let .tempbasal(rate, duration):
            if let error = verifyStatus() {
                processError(error)
                return
            }
            // unable to do temp basal during manual temp basal 😁
            if isManualTempBasal {
                processError(APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp"))
                return
            }
            guard !settings.closedLoop else {
                return
            }
            let roundedRate = pump.roundToSupportedBasalRate(unitsPerHour: Double(rate))
            pump.enactTempBasal(unitsPerHour: roundedRate, for: TimeInterval(duration) * 60) { error in
                if let error = error {
                    warning(.apsManager, "Announcement TempBasal failed with error: \(error.localizedDescription)")
                } else {
                    debug(.apsManager, "Announcement TempBasal succeeded")
                    self.announcementsStorage.storeAnnouncements([announcement], enacted: true)
                }
            }
        }
    }

    private func currentTemp(date: Date) -> TempBasal {
        let defaultTemp = { () -> TempBasal in
            guard let temp = storage.retrieve(OpenAPS.Monitor.tempBasal, as: TempBasal.self) else {
                return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: Date())
            }
            let delta = Int((date.timeIntervalSince1970 - temp.timestamp.timeIntervalSince1970) / 60)
            let duration = max(0, temp.duration - delta)
            return TempBasal(duration: duration, rate: temp.rate, temp: .absolute, timestamp: date)
        }()

        guard let state = pumpManager?.status.basalDeliveryState else { return defaultTemp }
        switch state {
        case .active:
            return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: date)
        case let .tempBasal(dose):
            let rate = Decimal(dose.unitsPerHour)
            let durationMin = max(0, Int((dose.endDate.timeIntervalSince1970 - date.timeIntervalSince1970) / 60))
            return TempBasal(duration: durationMin, rate: rate, temp: .absolute, timestamp: date)
        default:
            return defaultTemp
        }
    }

    private func enactSuggested() -> AnyPublisher<Void, Error> {
        guard let suggested = storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self) else {
            return Fail(error: APSError.apsError(message: "Suggestion not found")).eraseToAnyPublisher()
        }

        guard Date().timeIntervalSince(suggested.deliverAt ?? .distantPast) < Config.eхpirationInterval else {
            return Fail(error: APSError.apsError(message: "Suggestion expired")).eraseToAnyPublisher()
        }

        guard let pump = pumpManager else {
            return Fail(error: APSError.apsError(message: "Pump not set")).eraseToAnyPublisher()
        }

        // unable to do temp basal during manual temp basal 😁
        if isManualTempBasal {
            return Fail(error: APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp"))
                .eraseToAnyPublisher()
        }

        let basalPublisher: AnyPublisher<Void, Error> = Deferred { () -> AnyPublisher<Void, Error> in
            if let error = self.verifyStatus() {
                return Fail(error: error).eraseToAnyPublisher()
            }

            guard let rate = suggested.rate, let duration = suggested.duration else {
                // It is OK, no temp required
                debug(.apsManager, "No temp required")
                return Just(()).setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            return pump.enactTempBasal(unitsPerHour: Double(rate), for: TimeInterval(duration * 60)).map { _ in
                let temp = TempBasal(duration: duration, rate: rate, temp: .absolute, timestamp: Date())
                self.storage.save(temp, as: OpenAPS.Monitor.tempBasal)
                return ()
            }
            .eraseToAnyPublisher()
        }.eraseToAnyPublisher()

        let bolusPublisher: AnyPublisher<Void, Error> = Deferred { () -> AnyPublisher<Void, Error> in
            if let error = self.verifyStatus() {
                return Fail(error: error).eraseToAnyPublisher()
            }
            guard let units = suggested.units else {
                // It is OK, no bolus required
                debug(.apsManager, "No bolus required")
                return Just(()).setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            return pump.enactBolus(units: Double(units), automatic: true).map { _ in
                self.bolusProgress.send(0)
                return ()
            }
            .eraseToAnyPublisher()
        }.eraseToAnyPublisher()

        return basalPublisher.flatMap { bolusPublisher }.eraseToAnyPublisher()
    }

    private func reportEnacted(received: Bool) {
        if let suggestion = storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self), suggestion.deliverAt != nil {
            var enacted = suggestion
            enacted.timestamp = Date()
            enacted.recieved = received

            storage.save(enacted, as: OpenAPS.Enact.enacted)

            // Create a tdd.json
            tdd(enacted_: enacted)

            debug(.apsManager, "Suggestion enacted. Received: \(received)")
            DispatchQueue.main.async {
                self.broadcaster.notify(EnactedSuggestionObserver.self, on: .main) {
                    $0.enactedSuggestionDidUpdate(enacted)
                }
            }
            nightscout.uploadStatus()
        }
    }

    private func tdd(enacted_: Suggestion) {
        // Add to tdd.json:
        let preferences = settingsManager.preferences
        let currentTDD = enacted_.tdd ?? 0
        let file = OpenAPS.Monitor.tdd
        let tdd = TDD(
            TDD: currentTDD,
            timestamp: Date(),
            id: UUID().uuidString
        )
        var uniqEvents: [TDD] = []
        storage.transaction { storage in
            storage.append(tdd, to: file, uniqBy: \.id)
            uniqEvents = storage.retrieve(file, as: [TDD].self)?
                .filter { $0.timestamp.addingTimeInterval(14.days.timeInterval) > Date() }
                .sorted { $0.timestamp > $1.timestamp } ?? []
            var total: Decimal = 0
            var indeces: Decimal = 0
            for uniqEvent in uniqEvents {
                if uniqEvent.TDD > 0 {
                    total += uniqEvent.TDD
                    indeces += 1
                }
            }
            let entriesPast2hours = storage.retrieve(file, as: [TDD].self)?
                .filter { $0.timestamp.addingTimeInterval(2.hours.timeInterval) > Date() }
                .sorted { $0.timestamp > $1.timestamp } ?? []
            var totalAmount: Decimal = 0
            var nrOfIndeces: Decimal = 0
            for entry in entriesPast2hours {
                if entry.TDD > 0 {
                    totalAmount += entry.TDD
                    nrOfIndeces += 1
                }
            }
            if indeces == 0 {
                indeces = 1
            }
            if nrOfIndeces == 0 {
                nrOfIndeces = 1
            }
            let average14 = total / indeces
            let average2hours = totalAmount / nrOfIndeces
            let weight = preferences.weightPercentage
            let weighted_average = weight * average2hours + (1 - weight) * average14
            let averages = TDD_averages(
                average_total_data: roundDecimal(average14, 1),
                weightedAverage: roundDecimal(weighted_average, 1),
                past2hoursAverage: roundDecimal(average2hours, 1),
                date: Date()
            )
            storage.save(averages, as: OpenAPS.Monitor.tdd_averages)
            storage.save(Array(uniqEvents), as: file)
        }
    }

    private func roundDecimal(_ decimal: Decimal, _ digits: Double) -> Decimal {
        let rounded = round(Double(decimal) * pow(10, digits)) / pow(10, digits)
        return Decimal(rounded)
    }

    private func roundDouble(_ double: Double, _ digits: Double) -> Double {
        let rounded = round(Double(double) * pow(10, digits)) / pow(10, digits)
        return rounded
    }

    private func medianCalculation(array: [Double]) -> Double {
        guard !array.isEmpty else {
            return 0
        }
        let sorted = array.sorted()
        let length = array.count

        if length % 2 == 0 {
            return (sorted[length / 2 - 1] + sorted[length / 2]) / 2
        }
        return sorted[length / 2]
    }

    // Add to statistics.JSON
    private func statistics() {
        var testFile: [Statistics] = []
        var testIfEmpty = 0
        storage.transaction { storage in
            testFile = storage.retrieve(OpenAPS.Monitor.statistics, as: [Statistics].self) ?? []
            testIfEmpty = testFile.count
        }

        let updateThisOften = Int(settingsManager.preferences.updateInterval)

        // Only run every 30 minutesl
        if testIfEmpty != 0 {
            guard testFile[0].created_at.addingTimeInterval(updateThisOften.minutes.timeInterval) < Date()
            else {
                return
            }
        }

        let units = settingsManager.settings.units
        let preferences = settingsManager.preferences
        let carbs = storage.retrieve(OpenAPS.Monitor.carbHistory, as: [CarbsEntry].self)
        let tdds = storage.retrieve(OpenAPS.Monitor.tdd, as: [TDD].self)
        var currentTDD: Decimal = 0
        if tdds?.count ?? 0 > 0 {
            currentTDD = tdds?[0].TDD ?? 0
        }
        let carbs_length = carbs?.count ?? 0
        var carbTotal: Decimal = 0
        if carbs_length != 0 {
            for each in carbs! {
                if each.carbs != 0 {
                    carbTotal += each.carbs
                }
            }
        }
        var algo_ = "Oref0"

        if preferences.sigmoid, preferences.enableDynamicCR {
            algo_ = "Dynamic ISF + CR: Sigmoid"
        } else if preferences.sigmoid, !preferences.enableDynamicCR {
            algo_ = "Dynamic ISF: Sigmoid"
        } else if preferences.useNewFormula, preferences.enableDynamicCR {
            algo_ = "Dynamic ISF + CR: Logarithmic"
        } else if preferences.useNewFormula, !preferences.sigmoid,!preferences.enableDynamicCR {
            algo_ = "Dynamic ISF: Logarithmic"
        }

        let af = preferences.adjustmentFactor
        let insulin_type = preferences.curve
        let buildDate = Bundle.main.buildDate
        let version = Bundle.main.releaseVersionNumber
        let build = Bundle.main.buildVersionNumber
        let branch = Bundle.main.infoDictionary?["BuildBranch"] as? String ?? ""
        let copyrightNotice_ = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
        let pump_ = pumpManager?.localizedTitle ?? ""
        let cgm = settingsManager.settings.cgm
        let file = OpenAPS.Monitor.statistics
        var iPa: Decimal = 75
        if preferences.useCustomPeakTime {
            iPa = preferences.insulinPeakTime
        } else if preferences.curve.rawValue == "rapid-acting" {
            iPa = 65
        } else if preferences.curve.rawValue == "ultra-rapid" {
            iPa = 50
        }
        // Retrieve the loopStats data
        let lsData = storage.retrieve(OpenAPS.Monitor.loopStats, as: [LoopStats].self)?
            .sorted { $0.start > $1.start } ?? []
        var successRate: Double?
        var successNR = 0.0
        var errorNR = 0.0
        var minimumInt = 999.0
        var maximumInt = 0.0
        var minimumLoopTime = 9999.0
        var maximumLoopTime = 0.0
        var timeIntervalLoops = 0.0
        var previousTimeLoop = Date()
        var timeForOneLoop = 0.0
        var averageLoopTime = 0.0
        var timeForOneLoopArray: [Double] = []
        var medianLoopTime = 0.0
        var timeIntervalLoopArray: [Double] = []
        var medianInterval = 0.0
        var averageIntervalLoops = 0.0

        if !lsData.isEmpty {
            var i = 0.0

            if let loopEnd = lsData[0].end {
                previousTimeLoop = loopEnd
            }

            for each in lsData {
                if let loopEnd = each.end, let loopDuration = each.duration {
                    if each.loopStatus.contains("Success") {
                        successNR += 1
                    } else {
                        errorNR += 1
                    }
                    i += 1

                    timeIntervalLoops = (previousTimeLoop - each.start).timeInterval / 60
                    if timeIntervalLoops > 0.0, i != 1 {
                        timeIntervalLoopArray.append(timeIntervalLoops)
                    }

                    if timeIntervalLoops > maximumInt {
                        maximumInt = timeIntervalLoops
                    }
                    if timeIntervalLoops < minimumInt, i != 1 {
                        minimumInt = timeIntervalLoops
                    }

                    timeForOneLoop = loopDuration

                    timeForOneLoopArray.append(timeForOneLoop)
                    averageLoopTime += timeForOneLoop

                    if timeForOneLoop >= maximumLoopTime, timeForOneLoop != 0.0 {
                        maximumLoopTime = timeForOneLoop
                    }

                    if timeForOneLoop <= minimumLoopTime, timeForOneLoop != 0.0 {
                        minimumLoopTime = timeForOneLoop
                    }

                    previousTimeLoop = loopEnd
                }
            }

            successRate = (successNR / Double(i)) * 100
            averageIntervalLoops = ((lsData[0].end ?? lsData[lsData.count - 1].start) - lsData[lsData.count - 1].start)
                .timeInterval / 60 / Double(i)
            averageLoopTime /= Double(i)
            // Median values
            medianLoopTime = medianCalculation(array: timeForOneLoopArray)
            medianInterval = medianCalculation(array: timeIntervalLoopArray)
        }
        if minimumInt == 999.0 {
            minimumInt = 0.0
        }
        if minimumLoopTime == 9999.0 {
            minimumLoopTime = 0.0
        }
        // Time In Range (%) and Average Glucose (24 hours). This will be refactored later after some testing.
        let glucose = storage.retrieve(OpenAPS.Monitor.glucose_data, as: [GlucoseDataForStats].self)
        let length_ = glucose?.count ?? 0
        let endIndex = length_ - 1
        var bg: Decimal = 0
        var bgArray: [Double] = []
        var bgArray_1_: [Double] = []
        var bgArray_7_: [Double] = []
        var bgArray_30_: [Double] = []
        var bgArrayForTIR: [(bg_: Double, date_: Date)] = []
        var bgArray_1: [(bg_: Double, date_: Date)] = []
        var bgArray_7: [(bg_: Double, date_: Date)] = []
        var bgArray_30: [(bg_: Double, date_: Date)] = []
        var medianBG = 0.0
        var nr_bgs: Decimal = 0
        var nr_bgs_1: Decimal = 0
        var nr_bgs_7: Decimal = 0
        var nr_bgs_30: Decimal = 0

        var startDate = Date("1978-02-22T11:43:54.659Z")
        if endIndex >= 0 {
            startDate = glucose?[0].date
        }
        var end1 = false
        var end7 = false
        var end30 = false
        var bg_1: Decimal = 0
        var bg_7: Decimal = 0
        var bg_30: Decimal = 0
        var bg_total: Decimal = 0
        var j = -1

        // Make arrays for median calculations and calculate averages
        if endIndex >= 0 {
            for entry in glucose! {
                j += 1
                if entry.glucose > 0 {
                    bg += Decimal(entry.glucose)
                    bgArray.append(Double(entry.glucose))
                    bgArrayForTIR.append((Double(entry.glucose), entry.date))
                    nr_bgs += 1

                    if (startDate! - entry.date).timeInterval >= 8.64E4, !end1 {
                        end1 = true
                        bg_1 = bg / nr_bgs
                        bgArray_1 = bgArrayForTIR
                        bgArray_1_ = bgArray
                        nr_bgs_1 = nr_bgs
                        // time_1 = ((startDate ?? Date()) - entry.date).timeInterval
                    }
                    if (startDate! - entry.date).timeInterval >= 6.048E5, !end7 {
                        end7 = true
                        bg_7 = bg / nr_bgs
                        bgArray_7 = bgArrayForTIR
                        bgArray_7_ = bgArray
                        nr_bgs_7 = nr_bgs
                        // time_7 = ((startDate ?? Date()) - entry.date).timeInterval
                    }
                    if (startDate! - entry.date).timeInterval >= 2.592E6, !end30 {
                        end30 = true
                        bg_30 = bg / nr_bgs
                        bgArray_30 = bgArrayForTIR
                        bgArray_30_ = bgArray
                        nr_bgs_30 = nr_bgs
                        // time_30 = ((startDate ?? Date()) - entry.date).timeInterval
                    }
                }
            }
        }

        if nr_bgs > 0 {
            // Up to 91 days
            bg_total = bg / nr_bgs

            // If less then 24 hours of glucose data, use total instead
            if bg_1 == 0 {
                bg_1 = bg_total
                bgArray_1 = bgArrayForTIR
                end1 = true
                nr_bgs_1 = nr_bgs
            }
        }

        // Total median
        medianBG = medianCalculation(array: bgArray)
        var daysBG = 0.0
        var fullTime = 0.0

        if length_ > 0 {
            fullTime = (startDate! - glucose![endIndex].date).timeInterval
            daysBG = fullTime / 8.64E4
        }

        func tir(_ array: [(bg_: Double, date_: Date)]) -> (TIR: Double, hypos: Double, hypers: Double) {
            var timeInHypo = 0.0
            var timeInHyper = 0.0
            var hypos = 0.0
            var hypers = 0.0
            var i = -1
            var lastIndex = false
            let endIndex = array.count - 1

            var hypoLimit = settingsManager.preferences.low
            var hyperLimit = settingsManager.preferences.high
            if units == .mmolL {
                hypoLimit = hypoLimit / 0.0555
                hyperLimit = hyperLimit / 0.0555
            }

            var full_time = 0.0
            if endIndex > 0 {
                full_time = (array[0].date_ - array[endIndex].date_).timeInterval
            }

            while i < endIndex {
                i += 1
                let currentTime = array[i].date_
                var previousTime = currentTime

                if i + 1 <= endIndex {
                    previousTime = array[i + 1].date_
                } else {
                    lastIndex = true
                }
                if array[i].bg_ < Double(hypoLimit), !lastIndex {
                    timeInHypo += (currentTime - previousTime).timeInterval
                } else if array[i].bg_ >= Double(hyperLimit), !lastIndex {
                    timeInHyper += (currentTime - previousTime).timeInterval
                }
            }
            if timeInHypo == 0.0 {
                hypos = 0
            } else if full_time != 0.0 { hypos = (timeInHypo / full_time) * 100
            }
            if timeInHyper == 0.0 {
                hypers = 0
            } else if full_time != 0.0 { hypers = (timeInHyper / full_time) * 100
            }
            let TIR = 100 - (hypos + hypers)
            return (roundDouble(TIR, 1), roundDouble(hypos, 1), roundDouble(hypers, 1))
        }

        // HbA1c estimation (%, mmol/mol) 1 day
        var NGSPa1CStatisticValue: Decimal = 0.0
        var IFCCa1CStatisticValue: Decimal = 0.0
        if end1, bg_1 > 0 {
            NGSPa1CStatisticValue = (46.7 + bg_1) / 28.7 // NGSP (%)
            IFCCa1CStatisticValue = 10.929 *
                (NGSPa1CStatisticValue - 2.152) // IFCC (mmol/mol)  A1C(mmol/mol) = 10.929 * (A1C(%) - 2.15)
        }
        // 7 days
        var NGSPa1CStatisticValue_7: Decimal = 0.0
        var IFCCa1CStatisticValue_7: Decimal = 0.0
        if end7 {
            NGSPa1CStatisticValue_7 = (46.7 + bg_7) / 28.7 // NGSP (%)
            IFCCa1CStatisticValue_7 = 10.929 *
                (NGSPa1CStatisticValue_7 - 2.152) // IFCC (mmol/mol)  A1C(mmol/mol) = 10.929 * (A1C(%) - 2.15)
        }
        // 30 days
        var NGSPa1CStatisticValue_30: Decimal = 0.0
        var IFCCa1CStatisticValue_30: Decimal = 0.0
        if end30 {
            NGSPa1CStatisticValue_30 = (46.7 + bg_30) / 28.7 // NGSP (%)
            IFCCa1CStatisticValue_30 = 10.929 *
                (NGSPa1CStatisticValue_30 - 2.152) // IFCC (mmol/mol)  A1C(mmol/mol) = 10.929 * (A1C(%) - 2.15)
        }
        // Total days
        var NGSPa1CStatisticValue_total: Decimal = 0.0
        var IFCCa1CStatisticValue_total: Decimal = 0.0
        if nr_bgs > 0 {
            NGSPa1CStatisticValue_total = (46.7 + bg_total) / 28.7 // NGSP (%)
            IFCCa1CStatisticValue_total = 10.929 *
                (NGSPa1CStatisticValue_total - 2.152) // IFCC (mmol/mol)  A1C(mmol/mol) = 10.929 * (A1C(%) - 2.15)
        }

        var median = Durations(
            day: roundDecimal(Decimal(medianCalculation(array: bgArray_1.map(\.bg_))), 1),
            week: roundDecimal(Decimal(medianCalculation(array: bgArray_7.map(\.bg_))), 1),
            month: roundDecimal(Decimal(medianCalculation(array: bgArray_30.map(\.bg_))), 1),
            total: roundDecimal(Decimal(medianBG), 1)
        )

        var hbs = Durations(
            day: roundDecimal(NGSPa1CStatisticValue, 1),
            week: roundDecimal(NGSPa1CStatisticValue_7, 1),
            month: roundDecimal(NGSPa1CStatisticValue_30, 1),
            total: roundDecimal(NGSPa1CStatisticValue_total, 1)
        )

        // Convert to user-preferred unit
        let overrideHbA1cUnit = settingsManager.preferences.overrideHbA1cUnit

        if units == .mmolL {
            bg_1 = bg_1.asMmolL
            bg_7 = bg_7.asMmolL
            bg_30 = bg_30.asMmolL
            bg_total = bg_total.asMmolL

            median = Durations(
                day: roundDecimal(Decimal(medianCalculation(array: bgArray_1.map(\.bg_))).asMmolL, 1),
                week: roundDecimal(Decimal(medianCalculation(array: bgArray_7.map(\.bg_))).asMmolL, 1),
                month: roundDecimal(Decimal(medianCalculation(array: bgArray_30.map(\.bg_))).asMmolL, 1),
                total: roundDecimal(Decimal(medianBG).asMmolL, 1)
            )

            // Override if users sets overrideHbA1cUnit: true
            if !overrideHbA1cUnit {
                hbs = Durations(
                    day: roundDecimal(IFCCa1CStatisticValue, 1),
                    week: roundDecimal(IFCCa1CStatisticValue_7, 1),
                    month: roundDecimal(IFCCa1CStatisticValue_30, 1),
                    total: roundDecimal(IFCCa1CStatisticValue_total, 1)
                )
            }
        } else if units != .mmolL, overrideHbA1cUnit {
            hbs = Durations(
                day: roundDecimal(IFCCa1CStatisticValue, 1),
                week: roundDecimal(IFCCa1CStatisticValue_7, 1),
                month: roundDecimal(IFCCa1CStatisticValue_30, 1),
                total: roundDecimal(IFCCa1CStatisticValue_total, 1)
            )
        }

        // round output values
        daysBG = roundDouble(daysBG, 1)

        let glucose24Hours = storage.retrieve(OpenAPS.Monitor.glucose, as: [BloodGlucose].self)
        let nrOfCGMReadings = glucose24Hours?.count ?? 0

        let loopstat = LoopCycles(
            loops: Int(successNR + errorNR),
            errors: Int(errorNR),
            readings: nrOfCGMReadings,
            success_rate: Decimal(round(successRate ?? 0)),
            avg_interval: roundDecimal(Decimal(averageIntervalLoops), 1),
            median_interval: roundDecimal(Decimal(medianInterval), 1),
            min_interval: roundDecimal(Decimal(minimumInt), 1),
            max_interval: roundDecimal(Decimal(maximumInt), 1),
            avg_duration: Decimal(roundDouble(averageLoopTime, 2)),
            median_duration: Decimal(roundDouble(medianLoopTime, 2)),
            min_duration: roundDecimal(Decimal(minimumLoopTime), 2),
            max_duration: Decimal(roundDouble(maximumLoopTime, 1))
        )

        // TIR calcs for every case
        var oneDay_: (TIR: Double, hypos: Double, hypers: Double) = (0.0, 0.0, 0.0)
        var sevenDays_: (TIR: Double, hypos: Double, hypers: Double) = (0.0, 0.0, 0.0)
        var thirtyDays_: (TIR: Double, hypos: Double, hypers: Double) = (0.0, 0.0, 0.0)
        var totalDays_: (TIR: Double, hypos: Double, hypers: Double) = (0.0, 0.0, 0.0)

        // Get all TIR calcs for every case
        if end1 {
            oneDay_ = tir(bgArray_1)
        }
        if end7 {
            sevenDays_ = tir(bgArray_7)
        }
        if end30 {
            thirtyDays_ = tir(bgArray_30)
        }
        if nr_bgs > 0 {
            totalDays_ = tir(bgArrayForTIR)
        }

        let tir = Durations(
            day: roundDecimal(Decimal(oneDay_.TIR), 1),
            week: roundDecimal(Decimal(sevenDays_.TIR), 1),
            month: roundDecimal(Decimal(thirtyDays_.TIR), 1),
            total: roundDecimal(Decimal(totalDays_.TIR), 1)
        )

        let hypo = Durations(
            day: Decimal(oneDay_.hypos),
            week: Decimal(sevenDays_.hypos),
            month: Decimal(thirtyDays_.hypos),
            total: Decimal(totalDays_.hypos)
        )

        let hyper = Durations(
            day: Decimal(oneDay_.hypers),
            week: Decimal(sevenDays_.hypers),
            month: Decimal(thirtyDays_.hypers),
            total: Decimal(totalDays_.hypers)
        )

        let TimeInRange = TIRs(TIR: tir, Hypos: hypo, Hypers: hyper)

        let avgs = Durations(
            day: roundDecimal(bg_1, 1),
            week: roundDecimal(bg_7, 1),
            month: roundDecimal(bg_30, 1),
            total: roundDecimal(bg_total, 1)
        )

        let avg = Averages(Average: avgs, Median: median)

        let suggestion = storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self)

        let insulin = Ins(
            TDD: roundDecimal(currentTDD, 2),
            bolus: suggestion?.insulin?.bolus ?? 0,
            temp_basal: suggestion?.insulin?.temp_basal ?? 0,
            scheduled_basal: suggestion?.insulin?.scheduled_basal ?? 0
        )

        // SD and CV calculations for all durations:

        var sumOfSquares: Decimal = 0
        var sumOfSquares_1: Decimal = 0
        var sumOfSquares_7: Decimal = 0
        var sumOfSquares_30: Decimal = 0

        // Total
        for array in bgArray {
            if units == .mmolL {
                sumOfSquares += pow(Decimal(array).asMmolL - bg_total, 2)
            } else { sumOfSquares += pow(Decimal(array) - bg_total, 2) }
        }
        // One day
        for array_1 in bgArray_1_ {
            if units == .mmolL {
                sumOfSquares_1 += pow(Decimal(array_1).asMmolL - bg_1, 2)
            } else { sumOfSquares_1 += pow(Decimal(array_1) - bg_1, 2) }
        }
        // week
        for array_7 in bgArray_7_ {
            if units == .mmolL {
                sumOfSquares_7 += pow(Decimal(array_7).asMmolL - bg_7, 2)
            } else { sumOfSquares_7 += pow(Decimal(array_7) - bg_7, 2) }
        }
        // month
        for array_30 in bgArray_30_ {
            if units == .mmolL {
                sumOfSquares_30 += pow(Decimal(array_30).asMmolL - bg_30, 2)
            } else { sumOfSquares_30 += pow(Decimal(array_30) - bg_30, 2) }
        }

        // Standard deviation and Coefficient of variation
        var sd_total = 0.0
        var cv_total = 0.0
        var sd_1 = 0.0
        var cv_1 = 0.0
        var sd_7 = 0.0
        var cv_7 = 0.0
        var sd_30 = 0.0
        var cv_30 = 0.0

        // Avoid division by zero
        if avgs.total < 1 || nr_bgs < 1 { sd_total = 0
            cv_total = 0 } else {
            sd_total = sqrt(Double(sumOfSquares / nr_bgs))
            cv_total = sd_total / Double(bg_total) * 100
        }
        if avgs.day < 1 || nr_bgs_1 < 1 {
            sd_1 = 0
            cv_1 = 0
        } else {
            sd_1 = sqrt(Double(sumOfSquares_1 / nr_bgs_1))
            cv_1 = sd_1 / Double(bg_1) * 100
        }
        if avgs.week < 1 || nr_bgs_7 < 1 {
            sd_7 = 0
            cv_7 = 0
        } else {
            sd_7 = sqrt(Double(sumOfSquares_7 / nr_bgs_7))
            cv_7 = sd_7 / Double(bg_7) * 100
        }
        if avgs.month < 1 || nr_bgs_30 < 1 { sd_30 = 0
            cv_30 = 0 } else { sd_30 = sqrt(Double(sumOfSquares_30 / nr_bgs_30))
            cv_30 = sd_30 / Double(bg_30) * 100
        }

        // Standard Deviations
        let standardDeviations = Durations(
            day: roundDecimal(Decimal(sd_1), 1),
            week: roundDecimal(Decimal(sd_7), 1),
            month: roundDecimal(Decimal(sd_30), 1),
            total: roundDecimal(Decimal(sd_total), 1)
        )

        // CV = standard deviation / sample mean x 100
        let cvs = Durations(
            day: roundDecimal(Decimal(cv_1), 1),
            week: roundDecimal(Decimal(cv_7), 1),
            month: roundDecimal(Decimal(cv_30), 1),
            total: roundDecimal(Decimal(cv_total), 1)
        )

        let variance = Variance(SD: standardDeviations, CV: cvs)

        let dailystat = Statistics(
            created_at: Date(),
            iPhone: UIDevice.current.getDeviceId,
            iOS: UIDevice.current.getOSInfo,
            Build_Version: version ?? "",
            Build_Number: build ?? "1",
            Branch: branch,
            CopyRightNotice: String(copyrightNotice_.prefix(32)),
            Build_Date: buildDate,
            Algorithm: algo_,
            AdjustmentFactor: af,
            Pump: pump_,
            CGM: cgm.rawValue,
            insulinType: insulin_type.rawValue,
            peakActivityTime: iPa,
            Carbs_24h: carbTotal,
            GlucoseStorage_Days: Decimal(daysBG),
            Statistics: Stats(
                Distribution: TimeInRange,
                Glucose: avg,
                HbA1c: hbs,
                LoopCycles: loopstat,
                Insulin: insulin,
                Variance: variance
            )
        )

        storage.transaction { storage in
            storage.append(dailystat, to: file, uniqBy: \.created_at)
            var uniqeEvents: [Statistics] = storage.retrieve(file, as: [Statistics].self)?
                .filter { $0.created_at.addingTimeInterval(24.hours.timeInterval) > Date() }
                .sorted { $0.created_at > $1.created_at } ?? []

            storage.save(Array(uniqeEvents), as: file)
        }

        nightscout.uploadStatistics(dailystat: dailystat)
        nightscout.uploadPreferences()
    }

    private func loopStats(loopStatRecord: LoopStats) {
        let file = OpenAPS.Monitor.loopStats

        var uniqEvents: [LoopStats] = []

        storage.transaction { storage in
            storage.append(loopStatRecord, to: file, uniqBy: \.start)
            uniqEvents = storage.retrieve(file, as: [LoopStats].self)?
                .filter { $0.start.addingTimeInterval(24.hours.timeInterval) > Date() }
                .sorted { $0.start > $1.start } ?? []

            storage.save(Array(uniqEvents), as: file)
        }
    }

    private func processError(_ error: Error) {
        warning(.apsManager, "\(error.localizedDescription)")
        lastError.send(error)
    }

    private func createBolusReporter() {
        bolusReporter = pumpManager?.createBolusProgressReporter(reportingOn: processQueue)
        bolusReporter?.addObserver(self)
    }

    private func updateStatus() {
        debug(.apsManager, "force update status")
        guard let pump = pumpManager else {
            return
        }

        if let omnipod = pump as? OmnipodPumpManager {
            omnipod.getPodStatus { _ in }
        }
        if let omnipodBLE = pump as? OmniBLEPumpManager {
            omnipodBLE.getPodStatus { _ in }
        }
    }

    private func clearBolusReporter() {
        bolusReporter?.removeObserver(self)
        bolusReporter = nil
        processQueue.asyncAfter(deadline: .now() + 0.5) {
            self.bolusProgress.send(nil)
            self.updateStatus()
        }
    }
}

private extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) -> AnyPublisher<DoseEntry?, Error> {
        Future { promise in
            self.enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { error in
                if let error = error {
                    debug(.apsManager, "Temp basal failed: \(unitsPerHour) for: \(duration)")
                    promise(.failure(error))
                } else {
                    debug(.apsManager, "Temp basal succeded: \(unitsPerHour) for: \(duration)")
                    promise(.success(nil))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func enactBolus(units: Double, automatic: Bool) -> AnyPublisher<DoseEntry?, Error> {
        Future { promise in
            // convert automatic
            let automaticValue = automatic ? BolusActivationType.automatic : BolusActivationType.manualRecommendationAccepted

            self.enactBolus(units: units, activationType: automaticValue) { error in
                if let error = error {
                    debug(.apsManager, "Bolus failed: \(units)")
                    promise(.failure(error))
                } else {
                    debug(.apsManager, "Bolus succeded: \(units)")
                    promise(.success(nil))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func cancelBolus() -> AnyPublisher<DoseEntry?, Error> {
        Future { promise in
            self.cancelBolus { result in
                switch result {
                case let .success(dose):
                    debug(.apsManager, "Cancel Bolus succeded")
                    promise(.success(dose))
                case let .failure(error):
                    debug(.apsManager, "Cancel Bolus failed")
                    promise(.failure(error))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func suspendDelivery() -> AnyPublisher<Void, Error> {
        Future { promise in
            self.suspendDelivery { error in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(()))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }

    func resumeDelivery() -> AnyPublisher<Void, Error> {
        Future { promise in
            self.resumeDelivery { error in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(()))
                }
            }
        }
        .mapError { APSError.pumpError($0) }
        .eraseToAnyPublisher()
    }
}

extension BaseAPSManager: PumpManagerStatusObserver {
    func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        let percent = Int((status.pumpBatteryChargeRemaining ?? 1) * 100)
        let battery = Battery(
            percent: percent,
            voltage: nil,
            string: percent > 10 ? .normal : .low,
            display: status.pumpBatteryChargeRemaining != nil
        )
        storage.save(battery, as: OpenAPS.Monitor.battery)
        storage.save(status.pumpStatus, as: OpenAPS.Monitor.status)
    }
}

extension BaseAPSManager: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {
        bolusProgress.send(Decimal(doseProgressReporter.progress.percentComplete))
        if doseProgressReporter.progress.isComplete {
            clearBolusReporter()
        }
    }
}

extension PumpManagerStatus {
    var pumpStatus: PumpStatus {
        let bolusing = bolusState != .noBolus
        let suspended = basalDeliveryState?.isSuspended ?? true
        let type = suspended ? StatusType.suspended : (bolusing ? .bolusing : .normal)
        return PumpStatus(status: type, bolusing: bolusing, suspended: suspended, timestamp: Date())
    }
}
