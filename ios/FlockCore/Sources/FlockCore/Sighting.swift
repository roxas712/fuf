import Foundation

/// A decoded record stamped with everything the device could not supply.
///
/// Location is optional on purpose. A sighting can arrive before GPS has a fix
/// -- cold start, parking garage, tunnel -- and dropping it would lose a real
/// detection. It is stored with null coordinates and the server interpolates
/// from the surrounding track.
public struct Sighting: Equatable, Sendable {
    public var sessionID: String
    public var seq: Int
    /// Phone wall clock at the moment the notification arrived.
    public var observedAt: Double
    public var msSinceBoot: UInt32
    public var bootEpoch: Int
    public var mac: String
    public var rssi: Int
    public var channel: Int
    public var radio: Int
    public var matchFlags: Int
    public var certainty: Int
    public var alertLevel: Int
    public var lat: Double?
    public var lon: Double?
    public var horizAcc: Double?
    public var speed: Double?
    public var uploadedAt: Double?

    /// Every field explicitly. Declaring any init suppresses the memberwise one,
    /// and rows also come back out of SQLite where no `SightingRecord` exists --
    /// without this the store has to fabricate a synthetic record and overwrite
    /// twelve fields, which fails silently the day someone adds a column and
    /// forgets an assignment.
    public init(sessionID: String, seq: Int, observedAt: Double,
                msSinceBoot: UInt32, bootEpoch: Int, mac: String, rssi: Int,
                channel: Int, radio: Int, matchFlags: Int, certainty: Int,
                alertLevel: Int, lat: Double?, lon: Double?,
                horizAcc: Double?, speed: Double?, uploadedAt: Double?) {
        self.sessionID = sessionID; self.seq = seq; self.observedAt = observedAt
        self.msSinceBoot = msSinceBoot; self.bootEpoch = bootEpoch
        self.mac = mac; self.rssi = rssi; self.channel = channel
        self.radio = radio; self.matchFlags = matchFlags
        self.certainty = certainty; self.alertLevel = alertLevel
        self.lat = lat; self.lon = lon; self.horizAcc = horizAcc
        self.speed = speed; self.uploadedAt = uploadedAt
    }

    /// Stamps a freshly received record.
    public init(record: SightingRecord,
                sessionID: String,
                seq: Int,
                observedAt: Double,
                bootEpoch: Int,
                fix: LocationFix?) {
        self.init(sessionID: sessionID, seq: seq, observedAt: observedAt,
                  msSinceBoot: record.msSinceBoot, bootEpoch: bootEpoch,
                  mac: record.macString, rssi: Int(record.rssi),
                  channel: Int(record.channel), radio: Int(record.radio.wireValue),
                  matchFlags: Int(record.matchFlags), certainty: Int(record.certainty),
                  alertLevel: Int(record.alertLevel),
                  lat: fix?.lat, lon: fix?.lon,
                  horizAcc: fix?.horizontalAccuracy, speed: fix?.speed,
                  uploadedAt: nil)
    }
}

/// A location fix, kept free of CoreLocation so the package builds and tests on
/// a Mac with no simulator. `LocationProvider` in the app maps CLLocation onto
/// this.
public struct LocationFix: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    /// Metres. Lets the server weight a fix taken in a tunnel differently from
    /// one under open sky.
    public var horizontalAccuracy: Double
    /// Metres/second. Constrains how far the phone travelled between samples.
    public var speed: Double?

    public init(lat: Double, lon: Double, horizontalAccuracy: Double, speed: Double?) {
        self.lat = lat
        self.lon = lon
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
    }
}
