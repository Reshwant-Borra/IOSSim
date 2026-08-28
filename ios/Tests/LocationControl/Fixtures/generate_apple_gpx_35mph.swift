import Foundation

let earthRadiusMeters = 6_371_000.0
let startLatitude = 37.3317
let startLongitude = -122.0307
let speedMetersPerSecond = 15.646
let secondsPerStep = 10.0
let distancePerStep = speedMetersPerSecond * secondsPerStep
let bearingsDegrees = [90.0, 90.0, 90.0, 45.0, 45.0, 0.0, 0.0, 270.0, 270.0, 315.0, 315.0, 180.0, 180.0, 135.0, 135.0, 90.0]
let startDate = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!

func destination(latitude: Double, longitude: Double, bearingDegrees: Double, distanceMeters: Double) -> (Double, Double) {
    let bearing = bearingDegrees * .pi / 180
    let lat1 = latitude * .pi / 180
    let lon1 = longitude * .pi / 180
    let angularDistance = distanceMeters / earthRadiusMeters
    let lat2 = asin(sin(lat1) * cos(angularDistance) + cos(lat1) * sin(angularDistance) * cos(bearing))
    let y = sin(bearing) * sin(angularDistance) * cos(lat1)
    let x = cos(angularDistance) - sin(lat1) * sin(lat2)
    let lon2 = lon1 + atan2(y, x)
    return (lat2 * 180 / .pi, ((lon2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360)) - 180)
}

var points: [(latitude: Double, longitude: Double, elevation: Double)] = [(startLatitude, startLongitude, 15.0)]
var latitude = startLatitude
var longitude = startLongitude
for (index, bearing) in bearingsDegrees.enumerated() {
    (latitude, longitude) = destination(
        latitude: latitude,
        longitude: longitude,
        bearingDegrees: bearing,
        distanceMeters: distancePerStep
    )
    let elevation = 15 + sin(Double(index + 1) / 3) * 4 + Double(index + 1) * 0.15
    points.append((latitude, longitude, elevation))
}

let formatter = ISO8601DateFormatter()
print(#"<?xml version="1.0" encoding="UTF-8"?>"#)
print(#"<gpx version="1.1" creator="IOSSim Apple GPX Control" xmlns="http://www.topografix.com/GPX/1/1">"#)
print("  <metadata>")
print("    <name>Apple GPX Core Location Control - 35 mph</name>")
print("    <desc>Deterministic 160 second route with 10 second waypoint spacing at 15.646 m/s.</desc>")
print("  </metadata>")
for (index, point) in points.enumerated() {
    let date = startDate.addingTimeInterval(Double(index) * secondsPerStep)
    print(String(format: #"  <wpt lat="%.8f" lon="%.8f">"#, point.latitude, point.longitude))
    print(String(format: "    <ele>%.2f</ele>", point.elevation))
    print("    <time>\(formatter.string(from: date))</time>")
    print("  </wpt>")
}
print("</gpx>")
