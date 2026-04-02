
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'place.dart';
import 'place_service.dart';

const _bristolCenter = LatLng(51.4558, -2.5884); // Cabot Circus-ish
const _defaultZoom = 13.0;

// TODO: Put your real API key here (or inject via --dart-define / env).
const String kGoogleApiKey = 'AIzaSyBE4LsC6I-OQwcsC3dmH4IrGTv3oFnhyT4';

void main() {
  runApp(const MapSearchApp());
}

class MapSearchApp extends StatelessWidget {
  const MapSearchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Map Search (Postcodes)',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const MapSearchScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MapSearchScreen extends StatefulWidget {
  const MapSearchScreen({super.key});

  @override
  State<MapSearchScreen> createState() => _MapSearchScreenState();
}

class _MapSearchScreenState extends State<MapSearchScreen> {
  final _queryCtrl = TextEditingController(text: 'cabot circus saver');
  final _service = PlacesService(kGoogleApiKey);

  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  List<Place> _results = [];
  bool _loading = false;
  String? _error;

  // Ask the user to confirm; if Yes, return the Place to the caller.
  Future<void> _confirmAndMaybeReturn(Place p) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: false,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Is it this address?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                if (p.postcode != null) Text('Postcode: ${p.postcode}'),
                if (p.formattedAddress.isNotEmpty) Text(p.formattedAddress),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('No'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Yes, use this address'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed == true) {
      debugPrint('[MapSearch] Selected shop: ${p.name} — '
        '${p.formattedAddress.isNotEmpty ? p.formattedAddress : (p.postcode ?? 'NO_ADDRESS')} '
        '(@ ${p.lat}, ${p.lng})');

      Navigator.pop(context, p);
    }
  }

  Future<void> _search() async {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final places = await _service.searchText(
        query: q,
        biasCenter: _bristolCenter,
        radiusMeters: 5000,
      );

      final markers = places.map((p) {
        final title = p.name;
        final snippet = [
          if (p.postcode != null) 'Postcode: ${p.postcode}',
          if (p.formattedAddress.isNotEmpty) p.formattedAddress,
        ].join('\n');

        return Marker(
          markerId: MarkerId(p.id),
          position: LatLng(p.lat, p.lng),
          // Tap the info window to confirm & select this place.
          infoWindow: InfoWindow(
            title: title,
            snippet: snippet,
            onTap: () => _confirmAndMaybeReturn(p),
          ),
        );
      }).toSet();

      setState(() {
        _results = places;
        _markers
          ..clear()
          ..addAll(markers);
      });

      await _zoomToFit(places);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _zoomToFit(List<Place> places) async {
    if (_mapController == null || places.isEmpty) return;

    if (places.length == 1) {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(places.first.lat, places.first.lng), 16),
      );
      return;
    }
    double? minLat, minLng, maxLat, maxLng;
    for (final p in places) {
      minLat = (minLat == null) ? p.lat : (p.lat < minLat ? p.lat : minLat);
      minLng = (minLng == null) ? p.lng : (p.lng < minLng ? p.lng : minLng);
      maxLat = (maxLat == null) ? p.lat : (p.lat > maxLat ? p.lat : maxLat);
      maxLng = (maxLng == null) ? p.lng : (p.lng > maxLng ? p.lng : maxLng);
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat!, minLng!),
      northeast: LatLng(maxLat!, maxLng!),
    );
    await _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search & Show Postcodes'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Type e.g. "cabot circus saver"',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : _search,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.location_searching),
                  label: const Text('Search'),
                ),
              ],
            ),
          ),

          // Map
          Expanded(
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(
                target: _bristolCenter,
                zoom: _defaultZoom,
              ),
              markers: _markers,
              onMapCreated: (c) => _mapController = c,
              myLocationButtonEnabled: false,
              myLocationEnabled: false,
              compassEnabled: true,
            ),
          ),

          // Results list with postcodes
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: _results.isEmpty ? 0 : 220 + bottom,
            padding: EdgeInsets.only(bottom: bottom),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
            ),
            child: _results.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      const SizedBox(height: 8),
                      const Text('Results near Bristol',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final p = _results[i];
                            return ListTile(
                              leading: const Icon(Icons.place_outlined),
                              title: Text(p.name),
                              subtitle: Text(
                                [
                                  if (p.postcode != null) 'Postcode: ${p.postcode}',
                                  p.formattedAddress
                                ].where((e) => e.isNotEmpty).join('\n'),
                              ),
                              // Tap a list row to confirm & select the place.
                              onTap: () => _confirmAndMaybeReturn(p),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),

          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('Dismiss'),
                )
              ],
            ),
        ],
      ),
    );
  }
}
