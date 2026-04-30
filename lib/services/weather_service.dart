import 'dart:convert';
import 'package:http/http.dart' as http;

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

class WeatherService {
  String _cleanLocationLabel(String raw) {
    return _cleanGovernorateLabel(raw)
        .replaceAll(RegExp(r'\s+City$', caseSensitive: false), '')
        .trim();
  }

  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  String _cleanGovernorateLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed
        .replaceAll(RegExp(r'\s+Governorate$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+Gov\.$', caseSensitive: false), '');
  }

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
