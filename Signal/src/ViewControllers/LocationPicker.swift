//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

//  Originally based on https://github.com/almassapargali/LocationPicker
//
//  Created by Almas Sapargali on 7/29/15.
//  Parts Copyright (c) 2015 almassapargali. All rights reserved.

import UIKit
import MapKit
import CoreLocation
import PromiseKit

@objc
public protocol LocationPickerDelegate {
    func didPickLocation(_ locationPicker: LocationPicker, location: Location)
}

@objc
public class LocationPicker: UIViewController {
    @objc public weak var delegate: LocationPickerDelegate?
    public var location: Location? { didSet { updateAnnotation() } }

    private let searchDistance: CLLocationDistance = 600

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var localSearch: MKLocalSearch?

    private lazy var mapView = MKMapView()

    private lazy var resultsController: LocationSearchResults = {
        let locationResults = LocationSearchResults()
        locationResults.onSelectLocation = { [weak self] in self?.selectedLocation($0) }
        return locationResults
    }()

    private lazy var searchController: UISearchController = {
        let searchController = UISearchController(searchResultsController: resultsController)
        searchController.searchResultsUpdater = self
        searchController.hidesNavigationBarDuringPresentation = false
        return searchController
    }()

    private lazy var searchBar: UISearchBar = {
        let searchBar = self.searchController.searchBar
        searchBar.placeholder = NSLocalizedString("LOCATION_PICKER_SEARCH_PLACEHOLDER",
                                                  comment: "A string indicating that the user can search for a location")
        return searchBar
    }()

    private static let SearchTermKey = "SearchTermKey"
    private var searchTimer: Timer?

    deinit {
        searchTimer?.invalidate()
        localSearch?.cancel()
        geocoder.cancelGeocode()
    }

    open override func loadView() {
        view = mapView

        let currentLocationButton = UIButton()
        currentLocationButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        currentLocationButton.clipsToBounds = true
        currentLocationButton.layer.cornerRadius = 24

        // This icon doesn't look right when it's actually centered do to its odd shape.
        currentLocationButton.setTemplateImageName("current-location-outline-24", tintColor: .white)
        currentLocationButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 0, bottom: 0, right: 2)

        view.addSubview(currentLocationButton)
        currentLocationButton.autoSetDimensions(to: CGSize(width: 48, height: 48))
        currentLocationButton.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 15)
        currentLocationButton.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: 15)

        currentLocationButton.addTarget(self, action: #selector(didPressCurrentLocation), for: .touchUpInside)
    }

    open override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("LOCATION_PICKER_TITLE", comment: "The title for the location picker view")

        navigationItem.leftBarButtonItem = createOWSBackButton()

        locationManager.delegate = self
        mapView.delegate = self

        OWSSearchBar.applyTheme(to: searchBar)

        searchBar.isTranslucent = false

        // When the search bar isn't translucent, it doesn't allow
        // setting the textField's backgroundColor. Instead, we need
        // to use the bacgrkound image.
        let backgroundImage = UIImage(
            color: Theme.searchFieldBackgroundColor,
            size: CGSize(width: 36, height: 36)
        ).withCornerRadius(10)
        searchBar.setSearchFieldBackgroundImage(backgroundImage, for: .normal)
        searchBar.searchTextPositionAdjustment = UIOffset(horizontal: 8.0, vertical: 0.0)
        searchBar.textField?.backgroundColor = .clear

        // Pre iOS 11, use the titleView for the search bar.
        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
        } else {
            navigationItem.titleView = searchBar
        }
        definesPresentationContext = true

        // Select a new location by long pressing
        let locationSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(addLocation))
        mapView.addGestureRecognizer(locationSelectGesture)

        // If we don't have location access granted, this does nothing.
        // If we do, this will start the map at the user's current location.
        mapView.showsUserLocation = true
        showCurrentLocation(requestAuthorizationIfNecessary: false)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        becomeFirstResponder()
        navigationController?.navigationBar.isTranslucent = false
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(true)
        navigationController?.navigationBar.isTranslucent = true
    }

    override public var canBecomeFirstResponder: Bool {
        return true
    }

    @objc func backButtonPressed(_ sender: UIButton) {
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }

    @objc func didPressCurrentLocation() {
        showCurrentLocation()
    }

    func showCurrentLocation(requestAuthorizationIfNecessary: Bool = true) {
        if requestAuthorizationIfNecessary { requestAuthorization() }
        locationManager.startUpdatingLocation()
    }

    func requestAuthorization() {
        switch CLLocationManager.authorizationStatus() {
        case .authorizedWhenInUse, .authorizedAlways:
            // We are already authorized, do nothing!
            break
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            // The user previous explicitly denied access. Point them to settings to re-enable.
            let alert = UIAlertController(
                title: NSLocalizedString("MISSING_LOCATION_PERMISSION_TITLE",
                                         comment: "Alert title indicating the user has denied location permissios"),
                message: NSLocalizedString("MISSING_LOCATION_PERMISSION_MESSAGE",
                                           comment: "Alert body indicating the user has denied location permissios"),
                preferredStyle: .alert
            )
            let openSettingsAction = UIAlertAction(
                title: CommonStrings.openSettingsButton,
                style: .default
            ) { _ in UIApplication.shared.openSystemSettings()  }
            alert.addAction(openSettingsAction)

            let dismissAction = UIAlertAction(title: CommonStrings.dismissButton, style: .cancel, handler: nil)
            alert.addAction(dismissAction)
            presentAlert(alert)
        @unknown default:
            owsFailDebug("Unknown")
        }
    }

    func updateAnnotation() {
        mapView.removeAnnotations(mapView.annotations)
        if let location = location {
            mapView.addAnnotation(location)
            mapView.selectAnnotation(location, animated: true)
        }
    }

    func showCoordinates(_ coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: searchDistance, longitudinalMeters: searchDistance)
        mapView.setRegion(region, animated: animated)
    }

    func selectLocation(location: CLLocation) {
        // add point annotation to map
        let annotation = MKPointAnnotation()
        annotation.coordinate = location.coordinate
        mapView.addAnnotation(annotation)

        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { response, error in
            if let error = error as NSError?, error.code != 10 { // ignore cancelGeocode errors
                // show error and remove annotation
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("BUTTON_OKAY",
                                                                       comment: "Label for the 'okay' button."),
                                              style: .cancel, handler: { _ in }))
                self.present(alert, animated: true) {
                    self.mapView.removeAnnotation(annotation)
                }
            } else if let placemark = response?.first {
                // get POI name from placemark if any
                let name = placemark.areasOfInterest?.first

                // pass user selected location too
                self.location = Location(name: name, location: location, placemark: placemark)
            }
        }
    }
}

extension LocationPicker: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The user requested we select their current location, do so and then stop listening for location updates.
        guard let location = locations.first else {
            return owsFailDebug("Unexpectedly received location update with no location")
        }
        // Only animate if this is not the first location we're showing.
        let shouldAnimate = self.location != nil
        showCoordinates(location.coordinate, animated: shouldAnimate)
        selectLocation(location: location)
        manager.stopUpdatingLocation()
    }

    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // If location permission was just granted, show the current location
        guard status == .authorizedWhenInUse else { return }
        showCurrentLocation()
    }
}

// MARK: Searching

extension LocationPicker: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        guard let term = searchController.searchBar.text else { return }

        // clear old results
        showItemsForSearchResult(nil)

        let searchTerm = term.trimmingCharacters(in: CharacterSet.whitespaces)
        if !searchTerm.isEmpty {
            // Search after a slight delay to debounce while the user is typing.
            searchTimer = Timer.weakScheduledTimer(withTimeInterval: 0.1,
                                                   target: self,
                                                   selector: #selector(searchFromTimer),
                                                   userInfo: [LocationPicker.SearchTermKey: searchTerm],
                                                   repeats: false)
        } else {
            searchTimer?.invalidate()
            searchTimer = nil
        }
    }

    @objc func searchFromTimer(_ timer: Timer) {
        guard let userInfo = timer.userInfo as? [String: AnyObject],
            let term = userInfo[LocationPicker.SearchTermKey] as? String else {
                return owsFailDebug("Unexpectedly attempted to search with no term")
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term

        if let location = locationManager.location {
            request.region = MKCoordinateRegion(center: location.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        }

        localSearch?.cancel()
        localSearch = MKLocalSearch(request: request)
        localSearch?.start { [weak self] response, _ in
            self?.showItemsForSearchResult(response)
        }
    }

    func showItemsForSearchResult(_ searchResult: MKLocalSearch.Response?) {
        resultsController.locations = searchResult?.mapItems.map { Location(name: $0.name, placemark: $0.placemark) } ?? []
        resultsController.tableView.reloadData()
    }

    func selectedLocation(_ location: Location) {
        // dismiss search results
        dismiss(animated: true) {
            // set location, this also adds annotation
            self.location = location
            self.showCoordinates(location.coordinate)
        }
    }
}

// MARK: Selecting location with gesture

extension LocationPicker {
    @objc func addLocation(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer.state == .began {
            let point = gestureRecognizer.location(in: mapView)
            let coordinates = mapView.convert(point, toCoordinateFrom: mapView)
            let location = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
            selectLocation(location: location)
        }
    }
}

// MARK: MKMapViewDelegate

extension LocationPicker: MKMapViewDelegate {
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation { return nil }

        let pin = MKPinAnnotationView(annotation: annotation, reuseIdentifier: "annotation")
        pin.pinTintColor = .ows_signalBlue
        pin.animatesDrop = annotation is MKPointAnnotation
        pin.rightCalloutAccessoryView = sendLocationButton()
        pin.canShowCallout = true
        return pin
    }

    func sendLocationButton() -> UIButton {
        let button = UIButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.setTemplateImageName("send-solid-24", tintColor: .ows_signalBlue)
        return button
    }

    public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
        if let location = location {
            delegate?.didPickLocation(self, location: location)
        }

        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }

    public func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        if let userPin = views.first(where: { $0.annotation is MKUserLocation }) {
            userPin.canShowCallout = false
        }
    }
}

// MARK: UISearchBarDelegate

class LocationSearchResults: UITableViewController {
    var locations: [Location] = []
    var onSelectLocation: ((Location) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        extendedLayoutIncludesOpaqueBars = true
        tableView.backgroundColor = Theme.backgroundColor
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return locations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LocationCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "LocationCell")

        let location = locations[indexPath.row]
        cell.textLabel?.text = location.name
        cell.textLabel?.textColor = Theme.primaryColor
        cell.detailTextLabel?.text = location.address
        cell.detailTextLabel?.textColor = Theme.secondaryColor
        cell.backgroundColor = Theme.backgroundColor

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelectLocation?(locations[indexPath.row])
    }
}

@objc
public class Location: NSObject {
    public let name: String?

    // difference from placemark location is that if location was reverse geocoded,
    // then location point to user selected location
    public let location: CLLocation
    public let placemark: CLPlacemark

    public var address: String? {
        guard let addressDictionary = placemark.addressDictionary,
            let lines = addressDictionary["FormattedAddressLines"] as? [String] else { return nil }
        return lines.joined(separator: ", ")
    }

    public var urlString: String {
        return "https://maps.google.com/maps?q=\(coordinate.latitude)%2C\(coordinate.longitude)"
    }

    enum LocationError: Error {
        case assertion
    }

    public func generateSnapshot() -> Promise<UIImage> {
        return Promise { resolver in
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 300, longitudinalMeters: 300)
            options.size = CGSize(width: 256, height: 256)

            // Always use 3x scale, the snapshotter uses the scale to determine how much
            // of the map the size should capture, but we always want to capture a constant
            // size image since we're sharing this with other phones.
            options.scale = 3

            MKMapSnapshotter(options: options).start(with: .global()) { snapshot, error in
                guard error == nil else {
                    owsFailDebug("Unexpectedly failed to capture map snapshot \(error!)")
                    return resolver.reject(LocationError.assertion)
                }

                guard let snapshot = snapshot else {
                    owsFailDebug("snapshot unexpectedly nil")
                    return resolver.reject(LocationError.assertion)
                }

                // Draw our location pin on the snapshot

                UIGraphicsBeginImageContextWithOptions(options.size, true, 3)
                snapshot.image.draw(at: .zero)

                let pinView = MKPinAnnotationView(annotation: nil, reuseIdentifier: nil)
                pinView.pinTintColor = .ows_signalBlue
                let pinImage = pinView.image

                var point = snapshot.point(for: self.coordinate)

                let pinCenterOffset = pinView.centerOffset
                point.x -= pinView.bounds.size.width / 2
                point.y -= pinView.bounds.size.height / 2
                point.x += pinCenterOffset.x
                point.y += pinCenterOffset.y
                pinImage?.draw(at: point)

                let image = UIGraphicsGetImageFromCurrentImageContext()

                UIGraphicsEndImageContext()

                guard let finalImage = image else {
                    owsFailDebug("image unexpectedly nil")
                    return resolver.reject(LocationError.assertion)
                }

                resolver.fulfill(finalImage)
            }
        }
    }

    public init(name: String?, location: CLLocation? = nil, placemark: CLPlacemark) {
        self.name = name
        self.location = location ?? placemark.location!
        self.placemark = placemark
    }

    @objc
    public func prepareAttachmentObjc() -> AnyPromise {
        return AnyPromise(prepareAttachment())
    }

    public func prepareAttachment() -> Promise<SignalAttachment> {
        return generateSnapshot().map(on: .global()) { image in
            guard let jpegData = image.jpegData(compressionQuality: 1.0) else {
                throw LocationError.assertion
            }

            let dataSource = DataSourceValue.dataSource(with: jpegData, utiType: kUTTypeJPEG as String)
            return SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeJPEG as String, imageQuality: .original)
        }
    }

    @objc
    public var messageText: String {
        // The message body will look something like:
        //
        // Place Name, 123 Street Name
        //
        // https://maps.google.com/maps

        if let address = address {
            return address + "\n\n" + urlString
        } else {
            return urlString
        }
    }
}

extension Location: MKAnnotation {
    @objc public var coordinate: CLLocationCoordinate2D {
        return location.coordinate
    }

    public var title: String? {
        return name ?? address ?? "\(coordinate.latitude), \(coordinate.longitude)"
    }
}
