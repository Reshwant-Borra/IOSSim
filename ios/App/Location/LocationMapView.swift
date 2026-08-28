import CoreLocation
import MapKit
import SwiftUI

/// The map surface for the Location tab: shows the selected point and the
/// actively simulated point (when different), and reports taps back as
/// coordinates. Purely observational — it never touches LocationCoordinator
/// or the DVT stack directly.
struct LocationMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    let selection: ResolvedPlace?
    let activeSimulation: ResolvedPlace?
    let onTap: (CLLocationCoordinate2D) -> Void

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let activeSimulation {
                    Marker(activeSimulation.name, systemImage: "location.fill", coordinate: activeSimulation.coordinate)
                        .tint(.green)
                }
                if let selection {
                    Marker(selection.name, coordinate: selection.coordinate)
                        .tint(.blue)
                }
                UserAnnotation()
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { screenPoint in
                if let coordinate = proxy.convert(screenPoint, from: .local) {
                    onTap(coordinate)
                }
            }
        }
    }
}
