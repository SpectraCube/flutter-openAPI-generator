class ModelDefinition {
  final String name;
  final List<ModelProperty> properties;
  final String description;

  ModelDefinition({
    required this.name,
    required this.properties,
    required this.description,
  });
}

class ModelProperty {
  final String name;
  final String originalName;
  final String type;
  final bool isRequired;
  final String description;

  ModelProperty({
    required this.name,
    required this.originalName,
    required this.type,
    required this.isRequired,
    required this.description,
  });
}
