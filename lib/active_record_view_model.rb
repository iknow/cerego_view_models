require "active_support"
require "active_record"

require "view_model"

require "cerego_active_record_patches"
require "lazily"

module Views; end

class ActiveRecordViewModel < ViewModel
  require 'active_record_view_model/association_data'
  require 'active_record_view_model/view_model_reference'
  require 'active_record_view_model/update_data'
  require 'active_record_view_model/update_context'
  require 'active_record_view_model/update_operation'

  ID_ATTRIBUTE = "id"
  TYPE_ATTRIBUTE = "_type"
  REFERENCE_ATTRIBUTE = "_ref"

  # An AR ViewModel wraps a single AR model
  attribute :model

  class << self
    attr_reader :_members, :_associations, :_list_attribute_name

    delegate :transaction, to: :model_class

    # The user-facing name of this viewmodel: serialized in the TYPE_ATTRIBUTE
    # field
    def view_name
      prefix = "#{Views.name}::"
      unless name.start_with?(prefix)
        raise "Illegal AR viewmodel: must be defined under module '#{prefix}'"
      end
      self.name[prefix.length..-1]
    end

    def for_view_name(name)
      raise ViewModel::DeserializationError.new("view name cannot be nil") if name.nil?

      class_name = "#{Views.name}::#{name}"
      viewmodel_class = class_name.safe_constantize
      if viewmodel_class.nil? || !(viewmodel_class < ActiveRecordViewModel)
        raise ViewModel::DeserializationError.new("ViewModel class '#{class_name}' not found")
      end
      viewmodel_class
    end

    def inherited(subclass)
      # copy ViewModel setup
      subclass._attributes = self._attributes

      subclass.initialize_members
    end

    def initialize_members
      @_members = {}
      @_associations = {}

      @generated_accessor_module = Module.new
      include @generated_accessor_module
    end

    # Specifies an attribute from the model to be serialized in this view
    def attribute(attr)
      _members[attr.to_s] = :attribute

      @generated_accessor_module.module_eval do
        define_method attr do
          model.public_send(attr)
        end

        define_method "serialize_#{attr}" do |json, serialize_context: self.class.new_serialize_context|
          value = self.public_send(attr)
          self.class.serialize(value, json, serialize_context: serialize_context)
        end

        define_method "deserialize_#{attr}" do |value, deserialize_context: self.class.new_deserialize_context|
          model.public_send("#{attr}=", value)
        end
      end
    end

    # Specifies that an attribute refers to an `acts_as_enum` constant.  This
    # provides special serialization behaviour to ensure that the constant's
    # string value is serialized rather than the model object.
    def acts_as_enum(*attrs)
      attrs.each do |attr|
        @generated_accessor_module.module_eval do
          redefine_method("serialize_#{attr}") do |json, serialize_context: self.class.new_serialize_context|
            value = self.public_send(attr)
            self.class.serialize(value.enum_constant, json, serialize_context: serialize_context)
          end
        end
      end
    end

    # Specifies that the model backing this viewmodel is a member of an
    # `acts_as_list` collection.
    def acts_as_list(attr = :position)
      @_list_attribute_name = attr

      @generated_accessor_module.module_eval do
        define_method("_list_attribute") do
          model.public_send(attr)
        end

        define_method("_list_attribute=") do |x|
          model.public_send(:"#{attr}=", x)
        end
      end
    end

    def _list_member?
      _list_attribute_name.present?
    end

    # Specifies an association from the model to be recursively serialized using
    # another viewmodel. If the target viewmodel is not specified, attempt to
    # locate a default viewmodel based on the name of the associated model.
    # TODO document harder
    # - +through+ names an ActiveRecord association that will be used like an
    #   ActiveRecord +has_many:through:+.
    # - +through_order_attr+ the through model is ordered by the given attribute
    #   (only applies to when +through+ is set).
    def association(association_name, viewmodel: nil, viewmodels: nil, shared: false, optional: shared, through: nil, through_order_attr: nil)
      if through
        model_association_name = through
        through_to             = association_name
      else
        model_association_name = association_name
        through_to             = nil
      end

      reflection = model_class.reflect_on_association(model_association_name)

      if reflection.nil?
        raise ArgumentError.new("Association #{association_name} not found in #{model_class.name} model")
      end

      viewmodel_spec = viewmodel || viewmodels

      association_data = AssociationData.new(reflection, viewmodel_spec, shared, optional, through_to, through_order_attr)

      _members[association_name.to_s]      = :association
      _associations[association_name.to_s] = association_data

      @generated_accessor_module.module_eval do
        define_method association_name do
          read_association(association_name)
        end

        define_method :"serialize_#{association_name}" do |json, serialize_context: self.class.new_serialize_context|
          associated = self.public_send(association_name)

          case
          when associated.nil?
            json.null!
          when association_data.through?
            json.array!(associated) do |through_target|
              ref = serialize_context.add_reference(through_target)
              json.set!(REFERENCE_ATTRIBUTE, ref)
            end
          when shared
            reference = serialize_context.add_reference(associated)
            json.set!(ActiveRecordViewModel::REFERENCE_ATTRIBUTE, reference)
          else
            self.class.serialize(associated, json, serialize_context: serialize_context)
          end
        end
      end
    end

    # Specify multiple associations at once
    def associations(*assocs)
      assocs.each { |assoc| association(assoc) }
    end

    ## Load an instance of the viewmodel by id
    def find(id, scope: nil, eager_include: true, serialize_context: new_serialize_context)
      find_scope = model_scope(eager_include: eager_include, serialize_context: serialize_context)
      find_scope = find_scope.merge(scope) if scope
      self.new(find_scope.find(id))
    end

    ## Load instances of the viewmodel by scope
    ## TODO: is this too much of a encapsulation violation?
    def load(scope: nil, eager_include: true, serialize_context: new_serialize_context)
      load_scope = model_scope(eager_include: eager_include, serialize_context: serialize_context)
      load_scope = load_scope.merge(scope) if scope
      load_scope.map { |model| self.new(model) }
    end

    def deserialize_from_view(subtree_hashes, references: {}, deserialize_context: new_deserialize_context)
      model_class.transaction do
        return_array = subtree_hashes.is_a?(Array)
        subtree_hashes = Array.wrap(subtree_hashes)

        updated_viewmodels =
          UpdateContext
            .build!(subtree_hashes, references, root_type: self)
            .run!(deserialize_context: deserialize_context)

        if return_array
          updated_viewmodels
        else
          updated_viewmodels.first
        end
      end
    end

    # TODO: Need to sort out preloading for polymorphic viewmodels: how do you
    # specify "when type A, go on to load these, but type B go on to load
    # those?"
    def eager_includes(serialize_context: new_serialize_context)
      # When serializing, we need to (recursively) include all intrinsic
      # associations and also those optional (incl. shared) associations
      # specified in the serialize_context.

      # when deserializing, we start with intrinsic non-shared associations. We
      # then traverse the structure of the tree to deserialize to map out which
      # optional or shared associations are used from each type. We then explore
      # from the root type to build an preload specification that will include
      # them all. (We can subsequently use this same structure to build a
      # serialization context featuring the same associations.)

      _associations.each_with_object({}) do |(assoc_name, association_data), h|
        next if association_data.optional? && !serialize_context.includes_association?(assoc_name)

        if association_data.polymorphic?
          # The regular AR preloader doesn't support child includes that are
          # conditional on type.  If we want to go through polymorphic includes,
          # we'd need to manually specify the viewmodel spec so that the
          # possible target classes are know, and also use our own preloader
          # instead of AR.
          children = {}
        else
          # if we have a known non-polymorphic association class, we can find
          # child viewmodels and recurse.
          viewmodel = association_data.viewmodel_class

          children = viewmodel.eager_includes(serialize_context: serialize_context.for_association(assoc_name))
        end

        h[assoc_name] = children
      end
    end

    # Returns the AR model class wrapped by this viewmodel. If this has not been
    # set via `model_class_name=`, attempt to automatically resolve based on the
    # name of this viewmodel.
    def model_class
      unless instance_variable_defined?(:@model_class)
        # try to auto-detect the model class based on our name
        self.model_class_name = self.view_name
      end

      @model_class
    end

    def model_scope(eager_include: true, serialize_context: new_serialize_context)
      scope = self.model_class.all
      if eager_include
        scope = scope.includes(self.eager_includes(serialize_context: serialize_context))
      end
      scope
    end

    # internal
    def _association_data(association_name)
      association_data = self._associations[association_name.to_s]
      raise ArgumentError.new("Invalid association") if association_data.nil?
      association_data
    end

    private

    # Set the AR model to be wrapped by this viewmodel
    def model_class_name=(name)
      type = name.to_s.camelize.safe_constantize
      raise ArgumentError.new("Could not find model class '#{name}'") if type.nil?
      self.model_class = type
    end

    # Set the AR model to be wrapped by this viewmodel
    def model_class=(type)
      if instance_variable_defined?(:@model_class)
        raise ArgumentError.new("Model class for ViewModel '#{self.name}' already set")
      end

      unless type < ActiveRecord::Base
        raise ArgumentError.new("'#{type.inspect}' is not a valid ActiveRecord model class")
      end
      @model_class = type
    end
  end

  delegate :model_class, to: 'self.class'
  delegate :id, to: :model

  def initialize(model = model_class.new)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)
  end

  def serialize_view(json, serialize_context: self.class.new_serialize_context)
    json.set!(ID_ATTRIBUTE, model.id)
    json.set!(TYPE_ATTRIBUTE, self.class.view_name)

    self.class._members.each do |member_name, member_type|
      member_context = serialize_context

      if member_type == :association
        member_context = member_context.for_association(member_name)
        association_data = self.class._association_data(member_name)
        next if association_data.optional? && !serialize_context.includes_association?(member_name)
      end

      json.set! member_name do
        self.public_send("serialize_#{member_name}", json, serialize_context: member_context)
      end
    end
  end

  def destroy!(deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      editable!(deserialize_context: deserialize_context)
      model.destroy!
    end
  end

  class UnimplementedException < Exception; end
  def unimplemented
    raise UnimplementedException.new
  end

  def load_associated(association_name)
    self.public_send(association_name)
  end

  def find_associated(association_name, id, eager_include: true, serialize_context: self.class.new_serialize_context)
    association_data = self.class._association_data(association_name)
    associated_viewmodel = association_data.viewmodel_class
    association_scope = self.model.association(association_name).association_scope
    associated_viewmodel.find(id, scope: association_scope, eager_include: eager_include, serialize_context: serialize_context)
  end

  # Create or update a single member of an associated collection. For an ordered
  # collection, the new item is added at the end appended.
  def append_associated(association_name, subtree_hashes, references: {}, deserialize_context: self.class.new_deserialize_context)
    return_array = subtree_hashes.is_a?(Array)
    subtree_hashes = Array.wrap(subtree_hashes)

    model_class.transaction do
      editable!(deserialize_context: deserialize_context)

      association_data = self.class._association_data(association_name)

      # TODO why not ArgumentError? The User was not responsible for this failure.
      raise ViewModel::DeserializationError.new("Cannot append to single association '#{association_name}'") unless association_data.collection?

      associated_viewmodel_class = association_data.viewmodel_class

      # Construct an update operation tree for the provided child hashes
      viewmodel_class = association_data.viewmodel_class
      update_context = UpdateContext.build!(subtree_hashes, references, root_type: viewmodel_class)

      # Set new parent
      new_parent = ActiveRecordViewModel::UpdateOperation::ParentData.new(association_data.reflection.inverse_of, self)
      update_context.root_updates.each { |update| update.reparent_to = new_parent }

      # Set place in list
      if associated_viewmodel_class._list_member?
        last_position = model.association(association_name).scope.maximum(associated_viewmodel_class._list_attribute_name) || 0
        base_position = last_position + 1.0
        update_context.root_updates.each_with_index { |update, index| update.reposition_to = base_position + index }
      end

      updated_viewmodels = update_context.run!(deserialize_context: deserialize_context)

      if return_array
        updated_viewmodels
      else
        updated_viewmodels.first
      end
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_associated(association_name, associated, deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      editable!(deserialize_context: deserialize_context)

      association_data = self.class._association_data(association_name)

      unless association_data.collection?
        raise ViewModel::DeserializationError.new("Cannot remove element from single association '#{association_name}'")
      end

      association = model.association(association_name)
      association.delete(associated.model)
    end
  end

  def read_association(association_name)
    association_data = self.class._association_data(association_name)

    associated = model.public_send(association_data.name)
    return nil if associated.nil?

    case
    when association_data.through?
      # associated here are join_table models; we need to get the far side out
      associated_viewmodel_class = association_data.viewmodel_class
      associated_viewmodels = associated.map do |through_model|
        model = through_model.public_send(association_data.source_reflection.name)
        associated_viewmodel_class.new(model)
      end
      if associated_viewmodel_class._list_member?
        associated_viewmodels.sort_by!(&:_list_attribute)
      end
      associated_viewmodels

    when association_data.collection?
      associated_viewmodel_class = association_data.viewmodel_class
      associated_viewmodels = associated.map { |x| associated_viewmodel_class.new(x) }
      if associated_viewmodel_class._list_member?
        associated_viewmodels.sort_by!(&:_list_attribute)
      end
      associated_viewmodels

    else
      associated_viewmodel_class = association_data.viewmodel_class_for_model(associated.class)
      associated_viewmodel_class.new(associated)
    end
  end



  ####### TODO LIST ########

  ## Eager loading
  # - Come up with a way to represent (and perform!) type-conditional eager
  #   loads for polymorphic associations

  ## Support for single table inheritance (if necessary)

  ## Ensure that we have correct behaviour when a polymorphic relationship is
  ## changed to an entity of a different type:
  # - does the old one get correctly garbage collected?

  ## Throw an error if the same entity is specified twice

  ### Controllers

  # - Consider better support for queries or pagination

  # - Consider ways to represent `has_many:through:`, if we want to allow
  #   skipping a view for the join. If so, how do we manage manipulation of the
  #   association itself, do we allow attributes (such as ordering?) on the join
  #   table?
end
