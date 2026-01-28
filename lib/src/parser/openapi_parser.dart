import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_openapi_generator/src/models/openapi_schema.dart';
import 'package:flutter_openapi_generator/src/models/model_definition.dart';
import 'package:flutter_openapi_generator/src/models/endpoint_definition.dart';

class OpenApiParser {
  Future<OpenApiSchema> parseSchema(String schemaPath) async {
    final json = await _loadSchema(schemaPath);
    return _parseJsonSchema(json);
  }

  Future<Map<String, dynamic>> _loadSchema(String schemaPath) async {
    if (schemaPath.startsWith('http://') || schemaPath.startsWith('https://')) {
      final response = await http.get(Uri.parse(schemaPath));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception(
            'Failed to load schema from URL: ${response.statusCode}');
      }
    } else {
      final file = File(schemaPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content);
      } else {
        throw Exception('Schema file not found: $schemaPath');
      }
    }
  }

  OpenApiSchema _parseJsonSchema(Map<String, dynamic> json) {
    final models = <ModelDefinition>[];
    final endpoints = <EndpointDefinition>[];

    // Parse models from components/schemas
    if (json['components'] != null && json['components']['schemas'] != null) {
      final schemas = json['components']['schemas'] as Map<String, dynamic>;
      for (final entry in schemas.entries) {
        try {
          final model = _parseModelDefinition(entry.key, entry.value);
          if (model != null) {
            models.add(model);
          }
        } catch (e) {
          print('Warning: Failed to parse model ${entry.key}: $e');
        }
      }
    }

    // Parse endpoints from paths
    if (json['paths'] != null) {
      final paths = json['paths'] as Map<String, dynamic>;
      for (final pathEntry in paths.entries) {
        final path = pathEntry.key;
        final pathMethods = pathEntry.value as Map<String, dynamic>;

        for (final methodEntry in pathMethods.entries) {
          final method = methodEntry.key.toUpperCase();
          final operation = methodEntry.value as Map<String, dynamic>;

          try {
            final endpoint = _parseEndpointDefinition(path, method, operation);
            if (endpoint != null) {
              endpoints.add(endpoint);
            }
          } catch (e) {
            print('Warning: Failed to parse endpoint $method $path: $e');
          }
        }
      }
    }

    return OpenApiSchema(models: models, endpoints: endpoints);
  }

  ModelDefinition? _parseModelDefinition(
      String name, Map<String, dynamic> schema) {
    if (schema['type'] == 'object' || schema['properties'] != null) {
      final properties = <ModelProperty>[];
      final required = <String>[];

      if (schema['required'] != null) {
        required.addAll((schema['required'] as List).cast<String>());
      }

      if (schema['properties'] != null) {
        final props = schema['properties'] as Map<String, dynamic>;
        for (final propEntry in props.entries) {
          final propName = propEntry.key;
          final propSchema = propEntry.value as Map<String, dynamic>;
          final isRequired = required.contains(propName);

          final property = _parseProperty(propName, propSchema, isRequired);
          if (property != null) {
            properties.add(property);
          }
        }
      }

      return ModelDefinition(
        name: name,
        properties: properties,
        description: schema['description'] ?? '',
      );
    }

    return null;
  }

  ModelProperty? _parseProperty(
      String name, Map<String, dynamic> schema, bool isRequired) {
    String type;
    bool isNullable = !isRequired;

    if (schema.containsKey('\$ref')) {
      final ref = schema['\$ref'] as String;
      type = _resolveRefType(ref);
    } else {
      // Check for OpenAPI 3.1.0 nullable patterns
      if (schema['nullable'] == true) {
        isNullable = true;
      }

      // Handle type arrays like ["integer", "null"]
      if (schema['type'] is List) {
        final typeArray = schema['type'] as List;
        if (typeArray.contains('null')) {
          isNullable = true;
        }
      }

      // Handle anyOf/oneOf with null
      if (schema.containsKey('anyOf') || schema.containsKey('oneOf')) {
        final anyOf = schema['anyOf'] as List<dynamic>?;
        final oneOf = schema['oneOf'] as List<dynamic>?;
        final types = anyOf ?? oneOf ?? [];

        for (final typeSchema in types) {
          if (typeSchema is Map<String, dynamic> &&
              typeSchema['type'] == 'null') {
            isNullable = true;
            break;
          }
        }
      }

      type = _getDartType(schema);
    }

    // Remove the ? suffix if it's already added by _getDartType
    if (type.endsWith('?') && isNullable) {
      // Type already has nullable suffix, don't add another
    } else if (isNullable && !type.endsWith('?')) {
      type = '$type?';
    }

    return ModelProperty(
      name: name,
      type: type,
      isRequired: isRequired,
      description: schema['description'] ?? '',
    );
  }

  String _getDartType(Map<String, dynamic> schema) {
    // Handle OpenAPI 3.1.0 union types (anyOf, oneOf, type arrays)
    if (schema.containsKey('anyOf') || schema.containsKey('oneOf')) {
      return _handleUnionTypes(schema);
    }

    // Handle type arrays like ["integer", "null"]
    if (schema['type'] is List) {
      return _handleTypeArray(schema['type'] as List);
    }

    final type = schema['type'] as String?;
    final format = schema['format'] as String?;

    switch (type) {
      case 'string':
        if (format == 'date-time') return 'DateTime';
        if (format == 'date') return 'DateTime';
        if (format == 'email') return 'String';
        if (schema['enum'] != null) return 'String';
        return 'String';
      case 'integer':
        if (format == 'int64') return 'int';
        return 'int';
      case 'number':
        if (format == 'float') return 'double';
        return 'double';
      case 'boolean':
        return 'bool';
      case 'array':
        final items = schema['items'] as Map<String, dynamic>?;
        if (items != null) {
          String itemType;
          if (items.containsKey('\$ref')) {
            final ref = items['\$ref'] as String;
            itemType = _resolveRefType(ref);
          } else {
            itemType = _getDartType(items);
          }
          return 'List<$itemType>';
        }
        return 'List<dynamic>';
      case 'object':
        if (schema['additionalProperties'] != null) {
          final additionalProps =
              schema['additionalProperties'] as Map<String, dynamic>?;
          if (additionalProps != null) {
            final valueType = _getDartType(additionalProps);
            return 'Map<String, $valueType>';
          }
        }
        return 'Map<String, dynamic>';
      default:
        return 'dynamic';
    }
  }

  String _handleUnionTypes(Map<String, dynamic> schema) {
    final anyOf = schema['anyOf'] as List<dynamic>?;
    final oneOf = schema['oneOf'] as List<dynamic>?;

    final types = anyOf ?? oneOf ?? [];
    if (types.isEmpty) return 'dynamic';

    // Find the primary type (non-null, non-object)
    String? primaryType;
    bool hasNull = false;

    for (final typeSchema in types) {
      if (typeSchema is Map<String, dynamic>) {
        if (typeSchema['type'] == 'null') {
          hasNull = true;
        } else if (primaryType == null && typeSchema['type'] != 'object') {
          primaryType = _getDartType(typeSchema);
        }
      }
    }

    if (primaryType == null) {
      // If no clear primary type, use the first non-null type
      for (final typeSchema in types) {
        if (typeSchema is Map<String, dynamic> &&
            typeSchema['type'] != 'null') {
          primaryType = _getDartType(typeSchema);
          break;
        }
      }
    }

    if (primaryType == null) return 'dynamic';

    return hasNull ? '$primaryType?' : primaryType;
  }

  String _handleTypeArray(List<dynamic> typeArray) {
    if (typeArray.isEmpty) return 'dynamic';

    // Find the primary type (non-null)
    String? primaryType;
    bool hasNull = false;

    for (final type in typeArray) {
      if (type == 'null') {
        hasNull = true;
      } else if (primaryType == null && type is String) {
        // Map OpenAPI types to Dart types
        switch (type) {
          case 'string':
            primaryType = 'String';
            break;
          case 'integer':
            primaryType = 'int';
            break;
          case 'number':
            primaryType = 'double';
            break;
          case 'boolean':
            primaryType = 'bool';
            break;
          case 'array':
            primaryType = 'List<dynamic>';
            break;
          case 'object':
            primaryType = 'Map<String, dynamic>';
            break;
          default:
            primaryType = 'dynamic';
        }
      }
    }

    if (primaryType == null) return 'dynamic';

    return primaryType;
  }

  EndpointDefinition? _parseEndpointDefinition(
      String path, String method, Map<String, dynamic> operation) {
    final operationId = operation['operationId'] as String?;
    final summary = operation['summary'] as String? ?? '';
    final description = operation['description'] as String? ?? '';
    final tags = <String>[];

    if (operation['tags'] != null) {
      final tagsList = operation['tags'] as List;
      for (final tag in tagsList) {
        if (tag is String) {
          tags.add(tag);
        }
      }
    }

    final parameters = <ParameterDefinition>[];
    if (operation['parameters'] != null) {
      final params = operation['parameters'] as List;
      for (final param in params) {
        final parameter = _parseParameter(param as Map<String, dynamic>);
        if (parameter != null) {
          parameters.add(parameter);
        }
      }
    }

    final requestBody =
        _parseRequestBody(operation['requestBody'] as Map<String, dynamic>?);
    final responses =
        _parseResponses(operation['responses'] as Map<String, dynamic>?);

    return EndpointDefinition(
      path: path,
      method: method,
      operationId: operationId,
      summary: summary,
      description: description,
      tags: tags,
      parameters: parameters,
      requestBody: requestBody,
      responses: responses,
    );
  }

  ParameterDefinition? _parseParameter(Map<String, dynamic> param) {
    final name = param['name'] as String?;
    final in_ = param['in'] as String?;
    final required = param['required'] as bool? ?? false;
    final schema = param['schema'] as Map<String, dynamic>?;

    if (name != null && in_ != null && schema != null) {
      String type;
      bool isNullable = !required;

      if (schema.containsKey('\$ref')) {
        final ref = schema['\$ref'] as String;
        type = _resolveRefType(ref);
      } else {
        type = _getDartType(schema);

        // Check for explicit nullable patterns only if not required
        if (!required) {
          if (schema['nullable'] == true) {
            isNullable = true;
          }

          // Handle type arrays like ["integer", "null"]
          if (schema['type'] is List) {
            final typeArray = schema['type'] as List;
            if (typeArray.contains('null')) {
              isNullable = true;
            }
          }

          // Handle anyOf/oneOf with null
          if (schema.containsKey('anyOf') || schema.containsKey('oneOf')) {
            final anyOf = schema['anyOf'] as List<dynamic>?;
            final oneOf = schema['oneOf'] as List<dynamic>?;
            final types = anyOf ?? oneOf ?? [];

            for (final typeSchema in types) {
              if (typeSchema is Map<String, dynamic> &&
                  typeSchema['type'] == 'null') {
                isNullable = true;
                break;
              }
            }
          }
        }
      }

      final finalType = isNullable && !type.endsWith('?') ? '$type?' : type.replaceAll('?', '');

      return ParameterDefinition(
        name: name,
        location: in_,
        type: finalType,
        isRequired: required,
      );
    }

    return null;
  }

  RequestBodyDefinition? _parseRequestBody(Map<String, dynamic>? requestBody) {
    if (requestBody == null) return null;

    final content = requestBody['content'] as Map<String, dynamic>?;
    if (content != null && content['application/json'] != null) {
      final jsonContent = content['application/json'] as Map<String, dynamic>;
      final schema = jsonContent['schema'] as Map<String, dynamic>?;

      if (schema != null) {
        String type;
        if (schema.containsKey('\$ref')) {
          final ref = schema['\$ref'] as String;
          type = _resolveRefType(ref);
        } else {
          type = _getDartType(schema);
        }
        return RequestBodyDefinition(type: type);
      }
    }

    return null;
  }

  Map<String, ResponseDefinition> _parseResponses(
      Map<String, dynamic>? responses) {
    final result = <String, ResponseDefinition>{};

    if (responses != null) {
      for (final entry in responses.entries) {
        final statusCode = entry.key;
        final response = entry.value as Map<String, dynamic>;

        // Handle $ref responses
        if (response.containsKey('\$ref')) {
          final ref = response['\$ref'] as String;
          final type = _resolveRefType(ref);
          result[statusCode] = ResponseDefinition(
            statusCode: statusCode,
            type: type,
            description: response['description'] as String? ?? '',
          );
          continue;
        }

        final content = response['content'] as Map<String, dynamic>?;

        String? type;
        if (content != null && content['application/json'] != null) {
          final jsonContent =
              content['application/json'] as Map<String, dynamic>;
          final schema = jsonContent['schema'] as Map<String, dynamic>?;

          if (schema != null) {
            if (schema.containsKey('\$ref')) {
              final ref = schema['\$ref'] as String;
              type = _resolveRefType(ref);
            } else {
              type = _getDartType(schema);
            }
          }
        }

        result[statusCode] = ResponseDefinition(
          statusCode: statusCode,
          type: type ?? 'dynamic',
          description: response['description'] as String? ?? '',
        );
      }
    }

    return result;
  }

  String _resolveRefType(String ref) {
    if (ref.startsWith('#/components/schemas/')) {
      final schemaName = ref.substring('#/components/schemas/'.length);
      return schemaName;
    }
    return 'dynamic';
  }
}
