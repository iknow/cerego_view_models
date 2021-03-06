# frozen_string_literal: true

# Simple visitor for cloning models through the tree structure defined by
# ViewModel::ActiveRecord. Owned associations will be followed and cloned, while
# non-owned referenced associations will be copied directly as references.
# Attributes (including association foreign keys not covered by ViewModel
# `association`s) will be copied from the original.
#
# To customize, subclasses may define methods `visit_x_view(node, new_model)`
# for each type they wish to affect. These callbacks may update attributes of
# the new model, and additionally can call `ignore!` or
# `ignore_association!(name)` to prune the current model or the target of the
# named association from the cloned tree.
class ViewModel::ActiveRecord::Cloner
  def clone(node)
    reset_state!

    new_model = node.model.dup

    pre_visit(node, new_model)
    return nil if ignored?

    if node.class.name
      class_name = node.class.name.underscore.gsub('/', '__')
      visit      = :"visit_#{class_name}"
      end_visit  = :"end_visit_#{class_name}"
    end

    if visit && respond_to?(visit, true)
      self.send(visit, node, new_model)
      return nil if ignored?
    end

    # visit the underlying viewmodel for each association, ignoring any
    # customization
    ignored_associations = @ignored_associations
    node.class._members.each do |name, association_data|
      next unless association_data.is_a?(ViewModel::ActiveRecord::AssociationData)

      reflection = association_data.direct_reflection

      if ignored_associations.include?(name)
        new_associated = association_data.collection? ? [] : nil
      else
        # Load the record associated with the old model
        associated = node.model.public_send(reflection.name)

        if associated.nil?
          new_associated = nil
        elsif !association_data.owned? && !association_data.through?
          # simply attach the associated target to the new model
          new_associated = associated
        else
          # Otherwise descend into the child, and attach the result
          build_vm = ->(model) do
            vm_class =
              if association_data.through?
                # descend into the synthetic join table viewmodel
                association_data.direct_viewmodel
              else
                association_data.viewmodel_class_for_model!(model.class)
              end

            vm_class.new(model)
          end

          new_associated =
            if ViewModel::Utils.array_like?(associated)
              associated.map { |m| clone(build_vm.(m)) }.compact
            else
              clone(build_vm.(associated))
            end
        end
      end

      new_association = new_model.association(reflection.name)
      new_association.writer(new_associated)
    end

    if end_visit && respond_to?(end_visit, true)
      self.send(end_visit, node, new_model)
    end

    post_visit(node, new_model)

    new_model
  end

  def pre_visit(node, new_model); end

  def post_visit(node, new_model); end

  private

  def reset_state!
    @ignored = false
    @ignored_associations = Set.new
  end

  def ignore!
    @ignored = true
  end

  def ignore_association!(name)
    @ignored_associations.add(name.to_s)
  end

  def ignored?
    @ignored
  end
end
