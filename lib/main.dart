import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:csv/csv.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'web_embed_stub.dart' if (dart.library.html) 'web_embed.dart';

// ★★★ 1. Google Maps APIキー ★★★
const String googleMapsApiKey = String.fromEnvironment(
  'GOOGLE_MAPS_API_KEY',
  defaultValue: 'YOUR_GOOGLE_API_KEY',
);

// ★★★ 2. 楽天アプリID ★★★
const String rakutenAppId = String.fromEnvironment(
  'RAKUTEN_APP_ID',
  defaultValue: 'YOUR_RAKUTEN_APP_ID',
);

// ★★★ 3. あなたのCloudflare Workers URL ★★★
// 例: 'https://damp-snow-b9f9.mnagai.workers.dev/'
// (末尾にスラッシュは入れないでください)
const String myProxyUrl = String.fromEnvironment(
  'CLOUDFLARE_PROXY_URL',
  defaultValue: 'YOUR_CLOUDFLARE_URL',
);

void main() {
  runApp(const EvHotelApp());
}

class Hotel {
  final String name; final String address; final double lat; final double lng; final String evType; final String chargerCount; final String output; final String maxCurrent; final String category; final String chargingFee; final String parkingFee; final String contact; final String reservation; final String manufacturer; final String auth; final String notes;
  final String csvPrice; final String csvImageUrl; final String csvAffiliateUrl; final String csvSiteUrl;

  Hotel({required this.name, required this.address, required this.lat, required this.lng, required this.evType, required this.chargerCount, required this.output, required this.maxCurrent, required this.category, required this.chargingFee, required this.parkingFee, required this.contact, required this.reservation, required this.manufacturer, required this.auth, required this.notes, required this.csvPrice, required this.csvImageUrl, required this.csvAffiliateUrl, required this.csvSiteUrl});
}

class RakutenData {
  final String? imageUrl; final String? hotelUrl; final int? minPrice; final String? reviewAverage;
  RakutenData({this.imageUrl, this.hotelUrl, this.minPrice, this.reviewAverage});
}

class MuniRecord {
  final String code;
  final String prefCode;
  final String prefName;
  final String name;
  MuniRecord({required this.code, required this.prefCode, required this.prefName, required this.name});
}

class BoundaryPoly {
  final List<LatLng> outer;
  final List<List<LatLng>> holes;
  BoundaryPoly({required this.outer, required this.holes});
}

class EvHotelApp extends StatelessWidget {
  const EvHotelApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EV Hotels Japan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _controller = Completer();
  Set<Marker> _hotelMarkers = {}; 
  Marker? _userMarker;
  Set<Polyline> _routePolylines = {};
  List<Hotel> _allHotels = []; List<Hotel> _filteredHotels = []; List<Hotel> _searchResults = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false; String _selectedFilter = 'すべて'; String _statusMessage = "";
  BitmapDescriptor? _iconTesla; BitmapDescriptor? _iconRapid; BitmapDescriptor? _iconNormal; BitmapDescriptor? _iconOther; BitmapDescriptor? _iconMyLocation;

  // キャッシュ
  final Map<String, RakutenData?> _rakutenCache = {};
  final Set<String> _prefetchedImageUrls = {};

  // Boundary search
  Map<String, String> _prefCodeByName = {};
  Map<String, List<MuniRecord>> _muniByName = {};
  bool _boundaryIndexLoaded = false;
  String _boundaryStatus = "";
  String _pendingBoundaryQuery = "";
  bool _boundaryActive = false;
  String _boundaryLabel = "";
  List<Hotel> _boundaryHotels = [];
  Set<Polygon> _boundaryPolygons = {};
  List<BoundaryPoly> _boundaryGeo = [];

  static const CameraPosition _kTokyoStation = CameraPosition(target: LatLng(35.681236, 139.767125), zoom: 8.0);

  @override
  void initState() {
    super.initState();
    _generateCustomIcons();
    _loadBoundaryIndex();
    _loadCsvData();
    _determinePosition(silent: true);
  }

  Future<void> _loadBoundaryIndex() async {
    setState(() { _boundaryStatus = "境界データ読み込み中"; });
    try {
      final raw = await rootBundle.loadString('assets/boundaries/index.json');
      final data = json.decode(raw) as Map<String, dynamic>;
      final prefs = (data['prefectures'] as List<dynamic>).cast<Map<String, dynamic>>();
      final munis = (data['municipalities'] as List<dynamic>).cast<Map<String, dynamic>>();

      final prefMap = <String, String>{};
      for (final p in prefs) {
        final name = p['name']?.toString() ?? '';
        final code = p['code']?.toString() ?? '';
        if (name.isEmpty || code.isEmpty) continue;
        prefMap[_normalizeName(name)] = code;
        prefMap[_normalizeName(_stripPrefSuffix(name))] = code;
      }

      final muniMap = <String, List<MuniRecord>>{};
      for (final m in munis) {
        final name = m['name']?.toString() ?? '';
        final code = m['code']?.toString() ?? '';
        final prefCode = m['prefCode']?.toString() ?? '';
        final prefName = m['pref']?.toString() ?? '';
        if (name.isEmpty || code.isEmpty || prefCode.isEmpty) continue;
        final rec = MuniRecord(code: code, prefCode: prefCode, prefName: prefName, name: name);
        void addKey(String k) {
          if (k.isEmpty) return;
          muniMap.putIfAbsent(k, () => []).add(rec);
        }
        addKey(_normalizeName(name));
        addKey(_normalizeName(_stripMuniSuffix(name)));
        if (prefName.isNotEmpty) {
          addKey(_normalizeName(prefName + name));
          addKey(_normalizeName(_stripPrefSuffix(prefName) + name));
        }
      }

      setState(() {
        _prefCodeByName = prefMap;
        _muniByName = muniMap;
        _boundaryIndexLoaded = true;
        _boundaryStatus = "境界データ読み込み完了";
      });
      if (_pendingBoundaryQuery.isNotEmpty) {
        final q = _pendingBoundaryQuery;
        _pendingBoundaryQuery = "";
        await _tryBoundarySearch(q);
      }
    } catch (e) {
      debugPrint("Boundary index load error: $e");
      setState(() { _boundaryStatus = "境界データ読み込み失敗"; });
    }
  }

  String _normalizeName(String input) {
    return input.replaceAll(RegExp(r'\\s+'), '').replaceAll('　', '').toLowerCase();
  }

  String _stripPrefSuffix(String name) {
    return name.replaceAll(RegExp(r'(都|道|府|県)$'), '');
  }

  String _stripMuniSuffix(String name) {
    return name.replaceAll(RegExp(r'(市|区|町|村)$'), '');
  }

  Future<void> _generateCustomIcons() async {
    _iconTesla = await _createMarkerBitmap(Colors.redAccent);
    _iconRapid = await _createMarkerBitmap(Colors.orange);
    _iconNormal = await _createMarkerBitmap(Colors.yellow);
    _iconOther = await _createMarkerBitmap(Colors.purple);
    _iconMyLocation = await _createMarkerBitmap(Colors.blueAccent);
    setState(() {}); 
  }

  Future<BitmapDescriptor> _createMarkerBitmap(Color color) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    const double size = 30.0; 
    final Paint paint = Paint()..color = color;
    final Paint borderPaint = Paint()..color = Colors.white..strokeWidth = 3.0..style = PaintingStyle.stroke;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2.2, paint);
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2.2, borderPaint);
    final ui.Image image = await pictureRecorder.endRecording().toImage(size.toInt(), size.toInt());
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(byteData!.buffer.asUint8List());
  }

  BitmapDescriptor _getIconForType(String evType) {
    final t = evType.replaceAll('　', ' ').trim().toLowerCase();
    if (t.contains('テスラ') || t.contains('tesla') || t.contains('supercharger')) return _iconTesla ?? BitmapDescriptor.defaultMarker;
    if (t.contains('急速') || t.contains('chademo') || t.contains('fast')) return _iconRapid ?? BitmapDescriptor.defaultMarker;
    if (t.contains('普通') || t.contains('200v') || t.contains('normal')) return _iconNormal ?? BitmapDescriptor.defaultMarker;
    return _iconOther ?? BitmapDescriptor.defaultMarker;
  }

  Future<RakutenData?> _fetchRakutenData(String hotelName) async {
    // 1. キャッシュ確認（これがあれば0秒表示）
    if (_rakutenCache.containsKey(hotelName)) return _rakutenCache[hotelName];
    if (rakutenAppId == 'YOUR_RAKUTEN_APP_ID') return null;

    RakutenData? result;
    
    // 2. 検索実行（専用プロキシ経由）
    result = await _searchApi(hotelName);
    
    // 3. なければお掃除して再検索
    if (result == null) {
      String cleanedName = _cleanHotelName(hotelName);
      if (cleanedName != hotelName && cleanedName.length > 2) {
        result = await _searchApi(cleanedName);
      }
    }
    
    // 4. キャッシュに保存
    _rakutenCache[hotelName] = result;
    return result;
  }

  String _cleanHotelName(String rawName) {
    String name = rawName;
    name = name.replaceAll(RegExp(r'[\(（].*?[\)）]'), '');
    if (name.contains('/')) name = name.split('/')[0];
    if (name.contains('／')) name = name.split('／')[0];
    return name.trim();
  }

  // ★修正：専用プロキシを使用する高速検索
  Future<RakutenData?> _searchApi(String keyword) async {
    if (myProxyUrl == 'YOUR_CLOUDFLARE_URL') return null;
    if (rakutenAppId == 'YOUR_RAKUTEN_APP_ID') return null;
    final targetUrl = 'https://app.rakuten.co.jp/services/api/Travel/KeywordHotelSearch/20170426?format=json&responseType=large&hotelThumbnailSize=3&keyword=${Uri.encodeComponent(keyword)}&applicationId=$rakutenAppId';
    
    try {
      // Cloudflare Workers経由でリクエスト
      final response = await http.get(Uri.parse('$myProxyUrl?url=${Uri.encodeComponent(targetUrl)}'));
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('application/json')) {
        return null;
      }
      
      if (response.statusCode == 200) {
        final trimmed = response.body.trimLeft();
        if (trimmed.startsWith('<')) {
          return null;
        }
        final data = json.decode(response.body);
        if (data['hotels'] != null && data['hotels'].isNotEmpty) {
          final basicInfo = data['hotels'][0]['hotel'][0]['hotelBasicInfo'];
          String pickBestImage(Map info) {
            String getStr(String key) => (info[key] ?? '').toString().trim();
            final candidates = [
              getStr('hotelImageUrl'),
              getStr('roomImageUrl'),
              getStr('hotelThumbnailUrl'),
              getStr('roomThumbnailUrl'),
            ];
            for (final url in candidates) {
              if (url.isNotEmpty) return url;
            }
            return '';
          }
          return RakutenData(
            imageUrl: pickBestImage(basicInfo),
            hotelUrl: basicInfo['hotelInformationUrl'],
            minPrice: basicInfo['hotelMinCharge'],
            reviewAverage: basicInfo['reviewAverage']?.toString(),
          );
        }
      }
    } catch (e) {
      debugPrint("API Error: $e");
    }
    return null;
  }

  Future<void> _searchPlaceAndMove(String query) async {
    if (query.isEmpty) return;
    if (googleMapsApiKey == 'YOUR_GOOGLE_API_KEY') { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google APIキーを設定してください'))); return; }
    setState(() { _statusMessage = "検索中..."; });
    
    final targetUrl = 'https://maps.googleapis.com/maps/api/place/findplacefromtext/json?input=$query&inputtype=textquery&fields=geometry&key=$googleMapsApiKey';
    
    try {
      // 検索も専用プロキシ経由に変更
      final response = await http.get(Uri.parse('$myProxyUrl?url=${Uri.encodeComponent(targetUrl)}'));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['candidates'] != null && data['candidates'].isNotEmpty) {
          final location = data['candidates'][0]['geometry']['location'];
          final GoogleMapController controller = await _controller.future;
          controller.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(location['lat'], location['lng']), zoom: 14.0)));
          setState(() { _statusMessage = ""; });
        } else { _zoomToFitResults(); }
      }
    } catch (e) { debugPrint("Search Error: $e"); }
  }

  Future<void> _determinePosition({bool silent = false}) async {
    if (!mounted && !silent) return;
    if (!silent) setState(() { _statusMessage = "現在地を取得中..."; });
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) { permission = await Geolocator.requestPermission(); if (permission == LocationPermission.denied) return; }
      if (permission == LocationPermission.deniedForever) return;
      Position position = await Geolocator.getCurrentPosition();
      setState(() { 
        _userMarker = Marker(markerId: const MarkerId("my_location"), position: LatLng(position.latitude, position.longitude), icon: _iconMyLocation ?? BitmapDescriptor.defaultMarker, infoWindow: const InfoWindow(title: "現在地"), zIndexInt: 1000); 
        _statusMessage = "";
      });
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(position.latitude, position.longitude), zoom: 14.0)));
    } catch (e) { debugPrint("Location Error: $e"); }
  }

  Future<void> _loadCsvData() async {
    try {
      final rawData = await rootBundle.loadString('assets/ev_hotels.csv');
      List<List<dynamic>> listData = const CsvToListConverter().convert(rawData);
      if (listData.isEmpty) return;
      var header = listData[0].map((e) => e.toString().trim().toLowerCase()).toList();
      int findIdx(List<String> keys) { for (var key in keys) { var idx = header.indexWhere((h) => h == key); if (idx != -1) return idx; } return -1; }
      var nameIdx = findIdx(['hotel_name', 'name', '施設名']); var addrIdx = findIdx(['address', '住所']); var latIdx = findIdx(['latitude', 'lat', '緯度']); var lngIdx = findIdx(['longitude', 'lng', '経度']); var evTypeIdx = findIdx(['charger_type', 'ev_type', '充電器タイプ']); var priceIdx = findIdx(['price_range', 'price', '価格']); var imgIdx = findIdx(['image_url', 'image']); var affIdx = findIdx(['affiliate_url', 'affiliate']); var siteIdx = findIdx(['関連サイト', 'site_url']);
      var countIdx = findIdx(['charger_count', '台数']); var outputIdx = findIdx(['出力', 'output']); var maxCurIdx = findIdx(['最大電流値', 'max_current']); var catIdx = findIdx(['種別', 'category']); var feeIdx = findIdx(['充電課金', 'charging_fee']); var parkIdx = findIdx(['駐車料金', 'parking_fee']); var contactIdx = findIdx(['連絡・申込', 'contact']); var resIdx = findIdx(['事前予約', 'reservation']); var makerIdx = findIdx(['メーカー', 'manufacturer']); var authIdx = findIdx(['認証', 'auth']); var noteIdx = findIdx(['備考', 'notes']);
      if (latIdx == -1) latIdx = 3; if (lngIdx == -1) lngIdx = 4; if (nameIdx == -1) nameIdx = 1;

      List<Hotel> loadedHotels = [];
      for (var i = 1; i < listData.length; i++) {
        try {
          var row = listData[i]; if (row.length <= lngIdx) continue;
          String getStr(int idx) => (idx != -1 && row.length > idx) ? row[idx].toString().trim() : "";
          double lat = 0.0; double lng = 0.0; try { lat = double.parse(getStr(latIdx)); lng = double.parse(getStr(lngIdx)); } catch(e) { continue; }
          if (lat == 0.0 || lng == 0.0) continue;
          loadedHotels.add(Hotel(name: getStr(nameIdx), address: getStr(addrIdx), lat: lat, lng: lng, evType: getStr(evTypeIdx), chargerCount: getStr(countIdx), output: getStr(outputIdx), maxCurrent: getStr(maxCurIdx), category: getStr(catIdx), chargingFee: getStr(feeIdx), parkingFee: getStr(parkIdx), contact: getStr(contactIdx), reservation: getStr(resIdx), manufacturer: getStr(makerIdx), auth: getStr(authIdx), notes: getStr(noteIdx), csvPrice: getStr(priceIdx), csvImageUrl: getStr(imgIdx), csvAffiliateUrl: getStr(affIdx), csvSiteUrl: getStr(siteIdx)));
        } catch (e) { debugPrint("CSV Row Parse Error: $e"); }
      }
      setState(() { _allHotels = loadedHotels; _applyFilter(); });
    } catch (e) { debugPrint("CSV Load Error: $e"); }
  }

  void _applyFilter() { setState(() { if (_selectedFilter == 'すべて') { _filteredHotels = _allHotels; } else { _filteredHotels = _allHotels.where((hotel) { final target = "${hotel.evType} ${hotel.output} ${hotel.category}"; return target.contains(_selectedFilter); }).toList(); } _createMarkers(); }); }
  void _createMarkers() { setState(() { _hotelMarkers = _filteredHotels.map((hotel) { return Marker(markerId: MarkerId(hotel.name), position: LatLng(hotel.lat, hotel.lng), icon: _getIconForType(hotel.evType), onTap: () => _showHotelDetails(hotel)); }).toSet(); }); }
  Future<void> _handleSearchSubmit(String query) async {
    if (query.isEmpty) return;
    if (!_boundaryIndexLoaded && _looksLikeBoundaryQuery(query)) {
      _pendingBoundaryQuery = query;
      setState(() { _boundaryStatus = "境界データ読み込み中"; _isSearching = false; _searchResults = []; });
      return;
    }
    if (await _tryBoundarySearch(query)) return;
    if (_searchResults.isNotEmpty && _searchResults.length < 5) { _zoomToFitResults(); return; }
    await _searchPlaceAndMove(query);
  }
  Future<void> _goToHotel(Hotel hotel) async { FocusScope.of(context).unfocus(); final GoogleMapController controller = await _controller.future; if (!mounted) return; setState(() { _isSearching = false; _searchController.clear(); }); controller.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(hotel.lat, hotel.lng), zoom: 15))); _showHotelDetails(hotel); }
  Future<void> _zoomToFitResults() async { if (_searchResults.isEmpty) return; final GoogleMapController controller = await _controller.future; if (_searchResults.length == 1) { controller.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(_searchResults[0].lat, _searchResults[0].lng), zoom: 15))); return; } double minLat = _searchResults[0].lat; double maxLat = _searchResults[0].lat; double minLng = _searchResults[0].lng; double maxLng = _searchResults[0].lng; for (var hotel in _searchResults) { if (hotel.lat < minLat) minLat = hotel.lat; if (hotel.lat > maxLat) maxLat = hotel.lat; if (hotel.lng < minLng) minLng = hotel.lng; if (hotel.lng > maxLng) maxLng = hotel.lng; } controller.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 50.0)); }
  bool _hasBoundaryCandidate(String query) {
    if (!_boundaryIndexLoaded) return false;
    final q = _normalizeName(query);
    if (q.isNotEmpty) {
      setState(() { _boundaryStatus = "境界判定: ${q}"; });
    }
    if (q.length < 2) return false;
    if (_prefCodeByName.containsKey(q)) return true;
    if (_muniByName.containsKey(q)) return true;
    for (final key in _prefCodeByName.keys) {
      if (q.startsWith(key)) return true;
    }
    return false;
  }

  bool _looksLikeBoundaryQuery(String query) {
    return RegExp(r'(都|道|府|県|市|区|町|村)$').hasMatch(query.trim());
  }

  void _onSearchChanged(String query) async {
    if (query.isEmpty) {
      setState(() { _isSearching = false; _searchResults = []; });
      return;
    }
    if (_looksLikeBoundaryQuery(query)) {
      setState(() { _isSearching = false; _searchResults = []; });
      if (!_boundaryIndexLoaded) {
        _pendingBoundaryQuery = query;
        setState(() { _boundaryStatus = "境界データ読み込み中"; });
        return;
      }
      await _tryBoundarySearch(query);
      return;
    }
    if (_hasBoundaryCandidate(query)) {
      if (await _tryBoundarySearch(query)) {
        setState(() { _isSearching = false; _searchResults = []; });
        return;
      }
    }
    setState(() {
      _isSearching = true;
      final lowerQuery = query.toLowerCase();
      _searchResults = _filteredHotels.where((hotel) {
        final content = "${hotel.name} ${hotel.address} ${hotel.evType} ${hotel.notes} ${hotel.contact} ${hotel.category} ${hotel.manufacturer}".toLowerCase();
        return content.contains(lowerQuery);
      }).toList();
    });
  }

  void _prefetchImageIfNeeded(String url) {
    if (url.isEmpty) return;
    if (_prefetchedImageUrls.contains(url)) return;
    _prefetchedImageUrls.add(url);
    try { precacheImage(CachedNetworkImageProvider(url), context); } catch (_) {}
  }

  Widget _hotelListImage(Hotel hotel, {bool large = false}) {
    Widget buildImage(String url) {
      final img = url.isNotEmpty && url != "nan" ? _proxiedImageUrl(url) : "";
      if (img.isEmpty) {
        return Container(
          color: Colors.grey[200],
          child: const Icon(Icons.hotel, size: 28, color: Colors.grey),
        );
      }
      return CachedNetworkImage(
        imageUrl: img,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(color: Colors.grey[200]),
        errorWidget: (context, url, error) => Container(color: Colors.grey[300], child: const Icon(Icons.hotel, size: 28, color: Colors.grey)),
      );
    }

    return FutureBuilder<RakutenData?>(
      future: _fetchRakutenData(hotel.name),
      builder: (context, snapshot) {
        final rakuten = snapshot.data;
        final rakutenImg = rakuten?.imageUrl ?? "";
        if (rakutenImg.isNotEmpty) return buildImage(rakutenImg);
        return buildImage(hotel.csvImageUrl);
      },
    );
  }

  List<BoundaryPoly> _polysFromGeometry(Map geometry) {
    final type = geometry['type']?.toString();
    final coords = geometry['coordinates'];
    if (type == 'Polygon' && coords is List) {
      return [_polyFromRings(coords)];
    }
    if (type == 'MultiPolygon' && coords is List) {
      return coords.map<BoundaryPoly>((rings) => _polyFromRings(rings as List)).toList();
    }
    return [];
  }

  BoundaryPoly _polyFromRings(List rings) {
    List<LatLng> ringToLatLng(List ring) {
      return ring.map<LatLng>((p) {
        final lat = (p[1] as num).toDouble();
        final lng = (p[0] as num).toDouble();
        return LatLng(lat, lng);
      }).toList();
    }
    final outer = ringToLatLng(rings.first as List);
    final holes = <List<LatLng>>[];
    for (var i = 1; i < rings.length; i++) {
      holes.add(ringToLatLng(rings[i] as List));
    }
    return BoundaryPoly(outer: outer, holes: holes);
  }

  bool _pointInRing(LatLng p, List<LatLng> ring) {
    bool inside = false;
    for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
          (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi + 0.0) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  bool _pointInPoly(LatLng p, BoundaryPoly poly) {
    if (!_pointInRing(p, poly.outer)) return false;
    for (final h in poly.holes) {
      if (_pointInRing(p, h)) return false;
    }
    return true;
  }

  LatLngBounds _boundsFromPolys(List<BoundaryPoly> polys) {
    double? minLat, maxLat, minLng, maxLng;
    for (final poly in polys) {
      for (final p in poly.outer) {
        minLat = minLat == null ? p.latitude : (p.latitude < minLat ? p.latitude : minLat);
        maxLat = maxLat == null ? p.latitude : (p.latitude > maxLat ? p.latitude : maxLat);
        minLng = minLng == null ? p.longitude : (p.longitude < minLng ? p.longitude : minLng);
        maxLng = maxLng == null ? p.longitude : (p.longitude > maxLng ? p.longitude : maxLng);
      }
    }
    return LatLngBounds(
      southwest: LatLng(minLat ?? 0, minLng ?? 0),
      northeast: LatLng(maxLat ?? 0, maxLng ?? 0),
    );
  }

  Future<void> _showPrefBoundary(String prefCode, String label) async {
    setState(() { _boundaryStatus = "境界読み込み: $prefCode"; });
    try {
      final raw = await rootBundle.loadString('assets/boundaries/pref/$prefCode.json');
      final data = json.decode(raw) as Map<String, dynamic>;
      final features = (data['features'] as List<dynamic>).cast<Map<String, dynamic>>();
      final polys = <BoundaryPoly>[];
      for (final f in features) {
        final geometry = f['geometry'] as Map<String, dynamic>;
        polys.addAll(_polysFromGeometry(geometry));
      }
      _applyBoundary(polys, label);
    } catch (e) {
      debugPrint("Pref boundary load error: $e");
      setState(() { _boundaryStatus = "境界読み込み失敗(pref $prefCode)"; });
      rethrow;
    }
  }

  Future<void> _showMuniBoundary(MuniRecord record) async {
    setState(() { _boundaryStatus = "境界読み込み: ${record.prefCode}"; });
    try {
      final raw = await rootBundle.loadString('assets/boundaries/muni/${record.prefCode}.json');
      final data = json.decode(raw) as Map<String, dynamic>;
      final features = (data['features'] as List<dynamic>).cast<Map<String, dynamic>>();
      final polys = <BoundaryPoly>[];
      for (final f in features) {
        final props = f['properties'] as Map<String, dynamic>;
        final city = props['N03_004']?.toString() ?? props['N03_003']?.toString() ?? props['N03_002']?.toString() ?? '';
        final ward = props['N03_005']?.toString() ?? '';
        final name = '$city$ward';
        if (_normalizeName(name) != _normalizeName(record.name)) continue;
        final geometry = f['geometry'] as Map<String, dynamic>;
        polys.addAll(_polysFromGeometry(geometry));
      }
      _applyBoundary(polys, record.name);
    } catch (e) {
      debugPrint("Muni boundary load error: $e");
      setState(() { _boundaryStatus = "境界読み込み失敗(muni ${record.prefCode})"; });
      rethrow;
    }
  }

  void _applyBoundary(List<BoundaryPoly> polys, String label) async {
    if (polys.isEmpty) return;
    final polygons = <Polygon>{};
    for (var i = 0; i < polys.length; i++) {
      final poly = polys[i];
      polygons.add(Polygon(
        polygonId: PolygonId('boundary_$i'),
        strokeColor: Colors.red,
        strokeWidth: 2,
        fillColor: Colors.transparent,
        points: poly.outer,
        holes: poly.holes,
      ));
    }
    setState(() {
      _boundaryGeo = polys;
      _boundaryPolygons = polygons;
      _boundaryHotels = [];
      _boundaryLabel = label;
      _boundaryActive = true;
      _boundaryStatus = "ホテル抽出中";
    });
    // Compute hotels after UI updates to reduce perceived freeze.
    Future(() {
      final bounds = _boundsFromPolys(polys);
      final boundaryHotels = <Hotel>[];
      for (final h in _filteredHotels) {
        if (h.lat < bounds.southwest.latitude || h.lat > bounds.northeast.latitude) continue;
        if (h.lng < bounds.southwest.longitude || h.lng > bounds.northeast.longitude) continue;
        final p = LatLng(h.lat, h.lng);
        for (final poly in polys) {
          if (_pointInPoly(p, poly)) {
            boundaryHotels.add(h);
            break;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _boundaryHotels = boundaryHotels;
        _boundaryStatus = "";
      });
    });
    if (!mounted) return;
    setState(() { _boundaryActive = true; });
    final controller = await _controller.future;
    controller.animateCamera(CameraUpdate.newLatLngBounds(_boundsFromPolys(polys), 40));
  }

  Future<bool> _tryBoundarySearch(String query) async {
    if (!_boundaryIndexLoaded) {
      setState(() { _boundaryStatus = "境界データ読み込み中"; });
      return false;
    }
    final q = _normalizeName(query);
    setState(() { _boundaryStatus = "境界検索: $q"; });
    try {
      if (_prefCodeByName.containsKey(q)) {
        final code = _prefCodeByName[q]!;
        await _showPrefBoundary(code, query).timeout(const Duration(seconds: 6));
        setState(() { _boundaryStatus = ""; });
        return true;
      }
    // prefecture prefix match
    for (final entry in _prefCodeByName.entries) {
      if (q.startsWith(entry.key)) {
        final remain = q.substring(entry.key.length);
        if (remain.isEmpty) {
          await _showPrefBoundary(entry.value, query).timeout(const Duration(seconds: 6));
          setState(() { _boundaryStatus = ""; });
          return true;
        }
        final list = _muniByName[remain];
        if (list != null && list.isNotEmpty) {
          final rec = list.firstWhere((r) => r.prefCode == entry.value, orElse: () => list.first);
          await _showMuniBoundary(rec).timeout(const Duration(seconds: 6));
          setState(() { _boundaryStatus = ""; });
          return true;
        }
      }
    }
    final list = _muniByName[q];
    if (list != null && list.isNotEmpty) {
      await _showMuniBoundary(list.first).timeout(const Duration(seconds: 6));
      setState(() { _boundaryStatus = ""; });
      return true;
    }
    } catch (e) {
      setState(() { _boundaryStatus = "境界読み込み失敗"; });
      return false;
    }
    setState(() { _boundaryStatus = "境界が見つかりません: $q"; });
    return false;
  }

  String _proxiedImageUrl(String url) {
    if (url.isEmpty) return url;
    if (myProxyUrl == 'YOUR_CLOUDFLARE_URL') return url;
    return '$myProxyUrl?url=${Uri.encodeComponent(url)}';
  }

  String _buildEmbedMapUrl(Hotel hotel) {
    if (googleMapsApiKey == 'YOUR_GOOGLE_API_KEY') return "";
    if (_userMarker != null) {
      final o = _userMarker!.position;
      return "https://www.google.com/maps/embed/v1/directions?key=$googleMapsApiKey&origin=${o.latitude},${o.longitude}&destination=${hotel.lat},${hotel.lng}&mode=driving";
    }
    return "https://www.google.com/maps/embed/v1/place?key=$googleMapsApiKey&q=${hotel.lat},${hotel.lng}";
  }

  Future<void> _openUrlInApp(String title, String url) async {
    if (url.isEmpty || url == "nan") return;
    if (kIsWeb) {
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (context) {
          final size = MediaQuery.of(context).size;
          return Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: SizedBox(
              width: size.width * 0.9,
              height: size.height * 0.85,
              child: Column(
                children: [
                  Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.centerLeft,
                    color: Colors.grey[100],
                    child: Row(
                      children: [
                        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: buildEmbeddedWebView(url)),
                ],
              ),
            ),
          );
        },
      );
    } else {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.inAppWebView);
      }
    }
  }

  void _showHotelDetails(Hotel hotel) {
    showDialog(context: context, barrierDismissible: true, builder: (context) {
      final Future<RakutenData?> rakutenFuture = _fetchRakutenData(hotel.name);
      return Dialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), insetPadding: const EdgeInsets.all(16), child: PointerInterceptor(child: FutureBuilder<RakutenData?>(future: rakutenFuture, builder: (context, snapshot) {
        
        String cleanText(String value) {
          final v = value.trim();
          if (v.isEmpty || v.toLowerCase() == "nan") return "";
          return v;
        }

        const bool shouldPreferRakuten = rakutenAppId != 'YOUR_RAKUTEN_APP_ID';
        String displayImage = shouldPreferRakuten ? "" : cleanText(hotel.csvImageUrl);
        String imageSource = displayImage.isNotEmpty ? "CSV" : "";
        String displayPrice = "";
        String displayUrl = hotel.csvAffiliateUrl.isNotEmpty ? hotel.csvAffiliateUrl : hotel.csvSiteUrl;
        String? review;
        bool isRakuten = false;
        
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data != null) { 
          final r = snapshot.data!; 
          if (r.imageUrl != null && cleanText(r.imageUrl!) != "") { displayImage = cleanText(r.imageUrl!); imageSource = "Rakuten"; }
          if (r.minPrice != null) {
            final formatter = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
            final formattedPrice = r.minPrice.toString().replaceAllMapped(formatter, (Match m) => '${m[1]},');
            displayPrice = "$formattedPrice円(税込)〜"; 
          }
          if (r.hotelUrl != null) displayUrl = r.hotelUrl!; 
          review = r.reviewAverage; 
          isRakuten = (r.minPrice != null); 
        } else if (snapshot.connectionState == ConnectionState.done && (snapshot.data == null || !snapshot.hasData)) {
          if (displayImage.isEmpty) { displayImage = cleanText(hotel.csvImageUrl); imageSource = displayImage.isNotEmpty ? "CSV" : ""; }
        }
        
        String buttonText = "関連サイトを見る";
        if (isRakuten || hotel.csvAffiliateUrl.isNotEmpty) { buttonText = "楽天トラベルで空室確認"; }

        Widget infoRow(String label, String value, {bool isLink = false, VoidCallback? onTap}) { if (value.isEmpty || value == "nan") return const SizedBox.shrink(); return Padding(padding: const EdgeInsets.only(bottom: 8.0), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 100, child: SelectableText(label, style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold))), Expanded(child: GestureDetector(onTap: isLink ? onTap : null, child: SelectableText(value, style: TextStyle(fontSize: 14, color: isLink ? Colors.blue : Colors.black87, decoration: isLink ? TextDecoration.underline : null))))])); }
        Widget sectionTitle(String title) => Padding(padding: const EdgeInsets.only(top: 16, bottom: 8), child: SelectableText(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)));
        final displayImageForLoad = _proxiedImageUrl(displayImage);
        _prefetchImageIfNeeded(displayImageForLoad);
        final size = MediaQuery.of(context).size;
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final imageHeight = size.width >= 900 ? 320.0 : 200.0;
        final cacheWidth = (MediaQuery.of(context).size.width * dpr).round();
        final cacheHeight = (imageHeight * dpr).round();
        return SizedBox(
          height: size.height * 0.9,
          width: double.infinity,
          child: Stack(children: [
            Column(children: [
              Stack(alignment: Alignment.topRight, children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: displayImageForLoad.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: displayImageForLoad,
                          height: imageHeight,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          memCacheWidth: cacheWidth,
                          memCacheHeight: cacheHeight,
                          maxWidthDiskCache: cacheWidth,
                          maxHeightDiskCache: cacheHeight,
                          fadeInDuration: const Duration(milliseconds: 120),
                          useOldImageOnUrlChange: true,
                          placeholder: (context, url) => Container(height: imageHeight, color: Colors.grey[200]),
                          imageBuilder: (context, provider) => Image(
                            image: provider,
                            height: imageHeight,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.high,
                          ),
                          errorWidget: (context, url, error) => Container(height: imageHeight, color: Colors.grey[300], child: const Icon(Icons.hotel, color: Colors.grey)),
                        )
                      : Container(height: imageHeight, color: Colors.grey[300], child: const Icon(Icons.hotel, color: Colors.grey, size: 50)),
                ),
                Padding(padding: const EdgeInsets.all(8.0), child: CircleAvatar(backgroundColor: Colors.white, radius: 20, child: IconButton(icon: const Icon(Icons.close, color: Colors.black), onPressed: () => Navigator.of(context).pop()))),
                if (imageSource.isNotEmpty) Positioned(left: 10, bottom: 10, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)), child: Text("Image: $imageSource", style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))),
                if (isRakuten) Positioned(bottom: 10, right: 10, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)), child: const Text("Rakuten Travel", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))),
              ]),
              Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 90), child: SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(hotel.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                if (review != null) ...[const SizedBox(height: 4), Row(children: [const Icon(Icons.star, color: Colors.amber, size: 18), SelectableText(" $review", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))])],
                const SizedBox(height: 4), SelectableText(hotel.address, style: const TextStyle(color: Colors.grey)), const SizedBox(height: 16),
                SizedBox(width: double.infinity, height: 45, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[600], foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), icon: const Icon(Icons.directions_car), label: const Text("アプリ内でルート案内", style: TextStyle(fontWeight: FontWeight.bold)), onPressed: () async {
                  if (googleMapsApiKey == 'YOUR_GOOGLE_API_KEY') { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google APIキーを設定してください'))); return; }
                  if (kIsWeb) {
                    final embedUrl = _buildEmbedMapUrl(hotel);
                    if (embedUrl.isNotEmpty) { await _openUrlInApp("ルート案内", embedUrl); }
                  } else {
                    final origin = _userMarker != null ? "${_userMarker!.position.latitude},${_userMarker!.position.longitude}" : "";
                    final String url = origin.isNotEmpty
                        ? "https://www.google.com/maps/dir/?api=1&origin=$origin&destination=${hotel.lat},${hotel.lng}"
                        : "https://www.google.com/maps/dir/?api=1&destination=${hotel.lat},${hotel.lng}";
                    final Uri uri = Uri.parse(url);
                    if (await canLaunchUrl(uri)) { await launchUrl(uri, mode: LaunchMode.inAppWebView); }
                  }
                })),
                const SizedBox(height: 16),
                if (displayPrice.isNotEmpty && displayPrice != "nan") Padding(padding: const EdgeInsets.only(bottom: 16.0), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: Colors.orange[50], borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.shade200)), child: SelectableText("目安: $displayPrice", style: TextStyle(color: Colors.orange[800], fontWeight: FontWeight.bold)))),
                if (hotel.csvSiteUrl.isNotEmpty && hotel.csvSiteUrl != "nan") Padding(padding: const EdgeInsets.only(bottom: 8.0), child: InkWell(onTap: () async { final Uri url = Uri.parse(hotel.csvSiteUrl); if (await canLaunchUrl(url)) await launchUrl(url); }, child: const Row(children: [Icon(Icons.link, color: Colors.blue, size: 18), SelectableText(" ホテル公式サイト / 関連ページ", style: TextStyle(color: Colors.blue, decoration: TextDecoration.underline))]))),
                const Divider(height: 10), 
                sectionTitle("⚡ EV充電スペック"), infoRow("タイプ", hotel.evType), infoRow("出力", hotel.output), infoRow("台数", hotel.chargerCount), infoRow("種別", hotel.category), infoRow("最大電流", hotel.maxCurrent), infoRow("メーカー", hotel.manufacturer),
                sectionTitle("🅿️ 利用・料金"), infoRow("充電課金", hotel.chargingFee), infoRow("駐車料金", hotel.parkingFee), infoRow("連絡・申込", hotel.contact), infoRow("事前予約", hotel.reservation),
                if (hotel.notes.isNotEmpty && hotel.notes != "nan") ...[sectionTitle("📝 備考"), Container(width: double.infinity, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)), child: SelectableText(hotel.notes, style: const TextStyle(fontSize: 13, height: 1.4)))],
              ])))),
            ]),
            if (displayUrl.isNotEmpty && displayUrl != "nan")
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700], foregroundColor: Colors.white, elevation: 5, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                        onPressed: () async { await _openUrlInApp(buttonText, displayUrl); },
                        child: Text(buttonText, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        );
      })));
    });
  }

  Widget _buildFilterChip(String label) {
    final isSelected = _selectedFilter == label;
    return Padding(padding: const EdgeInsets.only(right: 8.0), child: FilterChip(label: Text(label), selected: isSelected, onSelected: (bool selected) { setState(() { _selectedFilter = isSelected ? 'すべて' : label; _applyFilter(); }); }, backgroundColor: Colors.white, selectedColor: Colors.blue[100], checkmarkColor: Colors.blue[800], labelStyle: TextStyle(color: isSelected ? Colors.blue[900] : Colors.black87, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: isSelected ? Colors.blue : Colors.grey.shade300))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        GoogleMap(mapType: MapType.normal, initialCameraPosition: _kTokyoStation, markers: _hotelMarkers.union(_userMarker != null ? {_userMarker!} : {}), polylines: _routePolylines, polygons: _boundaryPolygons, myLocationEnabled: true, myLocationButtonEnabled: false, zoomControlsEnabled: false, onMapCreated: (GoogleMapController controller) { _controller.complete(controller); }),
        SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: Card(elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)), child: TextField(controller: _searchController, textInputAction: TextInputAction.search, onSubmitted: (value) { _handleSearchSubmit(value); }, decoration: const InputDecoration(hintText: "場所（新宿駅）、ホテル名、充電タイプ", prefixIcon: Icon(Icons.search), border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 15)), onChanged: _onSearchChanged))),
          SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(children: [_buildFilterChip('すべて'), _buildFilterChip('急速'), _buildFilterChip('普通'), _buildFilterChip('6kW'), _buildFilterChip('テスラ')])),
          if (_isSearching && _searchResults.isNotEmpty) PointerInterceptor(child: Container(margin: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]), constraints: const BoxConstraints(maxHeight: 250), child: ListView.separated(padding: EdgeInsets.zero, shrinkWrap: true, itemCount: _searchResults.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (context, index) { final hotel = _searchResults[index]; return ListTile(title: Text(hotel.name), subtitle: Text(hotel.address, maxLines: 1, overflow: TextOverflow.ellipsis), onTap: () => _goToHotel(hotel)); }))),
        ])),
        if (_boundaryActive)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            top: 0,
            child: DraggableScrollableSheet(
              initialChildSize: 0.55,
              minChildSize: 0.35,
              maxChildSize: 0.8,
              builder: (context, controller) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                    boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8)],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2))),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                        child: Row(
                          children: [
                            Expanded(child: Text("${_boundaryLabel} のホテル", style: const TextStyle(fontWeight: FontWeight.bold))),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() {
                                  _boundaryActive = false;
                                  _boundaryPolygons = {};
                                  _boundaryHotels = [];
                                  _boundaryGeo = [];
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _boundaryHotels.isEmpty
                            ? Center(child: Text(_boundaryStatus.isNotEmpty ? _boundaryStatus : "該当ホテルなし"))
                            : PointerInterceptor(
                                child: ListView.builder(
                                  controller: controller,
                                  itemCount: _boundaryHotels.length,
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                  itemBuilder: (context, index) {
                                    final hotel = _boundaryHotels[index];
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: InkWell(
                                        onTap: () => _goToHotel(hotel),
                                        child: Card(
                                          elevation: 2,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              ClipRRect(
                                                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                                child: SizedBox(
                                                  height: 180,
                                                  width: double.infinity,
                                                  child: _hotelListImage(hotel, large: true),
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.all(12),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(hotel.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                                    const SizedBox(height: 4),
                                                    Text(hotel.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black54)),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        Positioned(bottom: 30, right: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [if (_statusMessage.isNotEmpty) Container(padding: const EdgeInsets.all(8), color: Colors.white70, child: Text(_statusMessage, style: const TextStyle(fontSize: 10))), if (_boundaryStatus.isNotEmpty) Container(padding: const EdgeInsets.all(8), color: Colors.white70, child: Text(_boundaryStatus, style: const TextStyle(fontSize: 10))), const SizedBox(height: 8), FloatingActionButton(backgroundColor: Colors.blue, child: const Icon(Icons.my_location, color: Colors.white), onPressed: () { _determinePosition(); })])),
      ]),
    );
  }
}
