import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amf;
import 'package:flutter/material.dart';

import '../models/classroom.dart';
import '../providers/map_provider.dart';
import 'ar_nav_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapProvider mp = MapProvider();
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    mp.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    mp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: mp,
      builder: (context, _) {
        return Scaffold(
          body: Stack(
            children: [
              amf.AppleMap(
                initialCameraPosition: mp.cameraPosition,
                onMapCreated: mp.onMapCreated,
                myLocationEnabled: true,
                annotations: mp.annotations,
                polylines: mp.polylines,
              ),

              // Selection/Go panel overlays the map when a class is selected
              if (mp.selected != null && !mp.isJourneyActive)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _SelectionPanel(
                    name: mp.selected!.name,
                    subtitle: mp.selected!.id,
                    onGo: () {
                      final sel = mp.selected;
                      if (sel != null) {
                        if (!mp.isJourneyActive) {
                          mp.startJourney();
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ArNavScreen(destination: sel)),
                        );
                      }
                    },
                    onClose: mp.clearSelection,
                  ),
                ),

              // Map/AR toggle when journey is active
              if (mp.isJourneyActive)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton.tonal(
                            onPressed: null, // already on Map view
                            child: const Text('Map'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              final sel = mp.selected;
                              if (sel != null) {
                                Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => ArNavScreen(destination: sel)),
                                );
                              }
                            },
                            child: const Text('AR'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Search sheet is hidden when a class is selected or journey is active
              if (mp.selected == null && !mp.isJourneyActive)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _BottomSearchSheet(
                    controller: _controller,
                    results: mp.filtered,
                    onQuery: mp.setQuery,
                    onSelect: (c) => mp.focusOn(c),
                    onStart: mp.startJourney,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BottomSearchSheet extends StatelessWidget {
  final TextEditingController controller;
  final List<Classroom> results;
  final ValueChanged<String> onQuery;
  final ValueChanged<Classroom> onSelect;
  final VoidCallback onStart;

  const _BottomSearchSheet({
    required this.controller,
    required this.results,
    required this.onQuery,
    required this.onSelect,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 12, left: 12, right: 12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, -2)),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.search),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onQuery,
                    decoration: const InputDecoration(
                      hintText: 'Search classrooms',
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            SizedBox(
              height: 240,
              child: ListView.builder(
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final c = results[index];
                  return ListTile(
                    title: Text(c.name),
                    subtitle: Text(c.id),
                    onTap: () => onSelect(c),
                    trailing: IconButton(
                      icon: const Icon(Icons.directions_walk),
                      onPressed: () {
                        onSelect(c);
                        onStart();
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionPanel extends StatelessWidget {
  final String name;
  final String subtitle;
  final VoidCallback onGo;
  final VoidCallback onClose;

  const _SelectionPanel({
    required this.name,
    required this.subtitle,
    required this.onGo,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 12, left: 12, right: 12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, -2)),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            const SizedBox(width: 8),
            FilledButton(onPressed: onGo, child: const Text('Go')),
          ],
        ),
      ),
    );
  }
}
