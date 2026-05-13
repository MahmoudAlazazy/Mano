import 'dart:convert';
import 'package:http/http.dart' as http;

/// Current temperature and weather condition returned by [WeatherService.fetchCurrentWeather].
class WeatherResult {
  final double temperatureC;
  final int? weatherCode;
  final DateTime? observationTime;

  const WeatherResult({
    required this.temperatureC,
    required this.weatherCode,
    required this.observationTime,
  });
}

/// Resolved coordinates for a place, including cleaned display and governorate names.
class WeatherCoordinates {
  final double latitude;
  final double longitude;
  final String? resolvedName;
  final String? governorateName;

  const WeatherCoordinates({
    required this.latitude,
    required this.longitude,
    required this.resolvedName,
    this.governorateName,
  });
}

/// Handles geocoding (place name → coordinates), reverse geocoding
/// (coordinates → place name), and current weather fetching via Open-Meteo.
class WeatherService {
  /// Strips trailing "Governorate" / "Gov." suffixes and "City" from a label.
  String _cleanLocationLabel(String raw) {
    return _cleanGovernorateLabel(raw)
        .replaceAll(RegExp(r'\s+City$', caseSensitive: false), '')
        .trim();
  }

  /// Returns the first non-null, non-empty string from [values].
  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  /// Removes trailing "Governorate" or "Gov." from an admin-region name.
  String _cleanGovernorateLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed
        .replaceAll(RegExp(r'\s+Governorate$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+Gov\.$', caseSensitive: false), '');
  }

  /// Looks up [place] via the Open-Meteo geocoding API and returns its
  /// coordinates and cleaned display name. Throws if the place cannot be found.
  Future<WeatherCoordinates> resolveCoordinates(String place) async {
    final uri = Uri.https(
      'geocoding-api.open-meteo.com',
      '/v1/search',
      {
        'name': place,
        'count': '1',
        'language': 'en',
        'format': 'json',
      },
    );

    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to resolve location');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final results = decoded['results'];
    if (results is! List || results.isEmpty) {
      throw Exception('No coordinates found');
    }

    final first = results.first as Map<String, dynamic>;
    final latitude = (first['latitude'] as num).toDouble();
    final longitude = (first['longitude'] as num).toDouble();
    final name = first['name'] as String?;
    final admin1 = first['admin1'] as String?;

    return WeatherCoordinates(
      latitude: latitude,
      longitude: longitude,
      resolvedName: name != null ? _cleanLocationLabel(name) : null,
      governorateName:
          admin1 != null && admin1.trim().isNotEmpty
              ? _cleanGovernorateLabel(admin1)
              : null,
    );
  }

  /// Converts coordinates to a place name, trying Open-Meteo first and
  /// falling back to Nominatim (OpenStreetMap) if the first attempt fails
  /// or returns no usable name. Returns null if both providers fail.
  Future<WeatherCoordinates?> reverseGeocodeLocation({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final uri = Uri.https(
        'geocoding-api.open-meteo.com',
        '/v1/reverse',
        {
          'latitude': latitude.toString(),
          'longitude': longitude.toString(),
          'language': 'en',
          'format': 'json',
        },
      );

      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final results = decoded['results'];
        if (results is List && results.isNotEmpty) {
          final first = results.first as Map<String, dynamic>;
          // Prefer the locality name; fall back to the sub-region (admin2).
          final name = _firstNonEmpty([
            first['name'] as String?,
            first['admin2'] as String?,
          ]);
          final admin1 = first['admin1'] as String?;

          final displayName =
              name != null ? _cleanLocationLabel(name) : null;
          final governorateName =
              admin1 != null && admin1.trim().isNotEmpty
                  ? _cleanGovernorateLabel(admin1)
                  : null;

          if ((displayName != null && displayName.isNotEmpty) ||
              (governorateName != null && governorateName.isNotEmpty)) {
            return WeatherCoordinates(
              latitude: latitude,
              longitude: longitude,
              resolvedName: displayName ?? governorateName,
              governorateName: governorateName,
            );
          }
        }
      }
    } catch (_) {
      // Fall through to the secondary reverse-geocoding provider below.
    }

    // Secondary provider: Nominatim (OpenStreetMap).
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/reverse',
        {
          'lat': latitude.toString(),
          'lon': longitude.toString(),
          'format': 'jsonv2',
          'accept-language': 'en',
        },
      );
      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'mano-weather/1.0',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode != 200) {
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final address = decoded['address'];
      if (address is! Map<String, dynamic>) {
        return null;
      }

      // Walk address fields from most to least specific to find a display name.
      final displayNameRaw = _firstNonEmpty([
        address['city']?.toString(),
        address['town']?.toString(),
        address['village']?.toString(),
        address['municipality']?.toString(),
        address['suburb']?.toString(),
        address['county']?.toString(),
      ]);
      final governorateRaw = _firstNonEmpty([
        address['state']?.toString(),
        address['region']?.toString(),
        address['county']?.toString(),
      ]);

      final displayName =
          displayNameRaw != null ? _cleanLocationLabel(displayNameRaw) : null;
      final governorateName =
          governorateRaw != null
              ? _cleanGovernorateLabel(governorateRaw)
              : null;

      if ((displayName == null || displayName.isEmpty) &&
          (governorateName == null || governorateName.isEmpty)) {
        return null;
      }

      return WeatherCoordinates(
        latitude: latitude,
        longitude: longitude,
        resolvedName: displayName ?? governorateName,
        governorateName: governorateName,
      );
    } catch (_) {
      return null;
    }
  }

  /// Convenience wrapper around [reverseGeocodeLocation] that returns only
  /// the resolved display name, or null if the lookup fails.
  Future<String?> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    final details = await reverseGeocodeLocation(
      latitude: latitude,
      longitude: longitude,
    );
    return details?.resolvedName;
  }

  /// Fetches the current weather at the given coordinates from Open-Meteo
  /// and returns the temperature, weather code, and observation time.
  Future<WeatherResult> fetchCurrentWeather({
    required double latitude,
    required double longitude,
  }) async {
    final uri = Uri.https(
      'api.open-meteo.com',
      '/v1/forecast',
      {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current_weather': 'true',
      },
    );

    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch weather');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final current = decoded['current_weather'] as Map<String, dynamic>?;
    if (current == null) {
      throw Exception('Missing current weather');
    }

    final temp = (current['temperature'] as num).toDouble();
    final code = current['weathercode'] as int?;
    final timeString = current['time'] as String?;
    final time = timeString != null ? DateTime.tryParse(timeString) : null;

    return WeatherResult(
      temperatureC: temp,
      weatherCode: code,
      observationTime: time,
    );
  }
}
