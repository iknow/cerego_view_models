# frozen_string_literal: true

require 'view_model/access_control_error'

## Defines an access control discipline for a given action against a viewmodel.
##
## Access control is based around three edit check hooks: visible, editable and
## valid_edit. The visible determines whether a view can be seen. The editable
## check determines whether a view in its current state is eligible to be
## changed. The valid_edit change determines whether an attempted change is
## permitted. Each edit check returns a pair of boolean success and optional
## exception to raise.
class ViewModel::AccessControl
  Result = Struct.new(:permit, :error) do
    def initialize(permit, error: nil)
      raise ArgumentError.new("Successful AccessControl::Result may not have an error") if permit && error
      super(permit, error)
    end

    alias :permit? :permit

    # Merge this result with another access control result. Takes a block
    # returning a result, and returns a combined result for both tests. Access
    # is permitted if both results permit. Otherwise, access is denied with the
    # error value of the first denying Result.
    def merge(&_block)
      if permit?
        yield
      else
        self
      end
    end
  end

  Result::PERMIT = Result.new(true).freeze
  Result::DENY   = Result.new(false).freeze

  def initialize
    @initial_editability_store = {}
  end

  # Check that the user is permitted to view the record in its current state, in
  # the given context.
  def visible_check(_traversal_env)
    Result::DENY
  end

  # Editable checks during deserialization are always a combination of
  # `editable_check` and `valid_edit_check`, which express the following
  # separate properties. `The after_deserialize check passes if both checks are
  # successful.

  # Check that the record is eligible to be changed in its current state, in the
  # given context. This must be called before any edits have taken place (thus
  # checking against the initial state of the viewmodel), and if editing is
  # denied, an error must be raised only if an edit is later attempted. To be
  # overridden by viewmodel implementations.
  def editable_check(_traversal_env)
    Result::DENY
  end

  # Once the changes to be made to the viewmodel are known, check that the
  # attempted changes are permitted in the given context. For viewmodels with
  # transactional backing models, the changes may be made in advance to give the
  # edit checks the opportunity to compare values. To be overridden by viewmodel
  # implementations.
  def valid_edit_check(_traversal_env)
    Result::DENY
  end

  # Edit checks are invoked via traversal callbacks:
  include ViewModel::Callbacks

  before_visit do
    next if ineligible(view)

    result = visible_check(self)

    raise_if_error!(result) do
      message =
        if context.is_a?(ViewModel::DeserializeContext)
          "Attempt to deserialize into forbidden viewmodel '#{view.class.view_name}'"
        else
          "Attempt to serialize forbidden viewmodel '#{view.class.view_name}'"
        end

      ViewModel::AccessControlError.new(message, view.blame_reference)
    end
  end

  before_deserialize do
    next if ineligible(view)

    initial_result = editable_check(self)

    save_editability(view, initial_result)
  end

  on_change do
    next if ineligible(view)

    initial_result = fetch_editability(view)
    result = initial_result.merge do
      valid_edit_check(self)
    end

    raise_if_error!(result) do
      ViewModel::AccessControlError.new(
        "Illegal edit to viewmodel '#{view.class.view_name}'",
        view.blame_reference)
    end
  end

  after_deserialize do
    next if ineligible(view)
    cleanup_editability(view)
  end

  private

  def save_editability(view, initial_editability)
    if @initial_editability_store.has_key?(view.object_id)
      raise RuntimeError.new("Access control data already recorded for view #{view.to_reference}")
    end
    @initial_editability_store[view.object_id] = initial_editability
  end

  def fetch_editability(view)
    unless @initial_editability_store.has_key?(view.object_id)
      raise RuntimeError.new("No access control data recorded for view #{view.to_reference}")
    end
    @initial_editability_store.delete(view.object_id)
  end

  def cleanup_editability(view)
    @initial_editability_store.delete(view.object_id)
  end

  def ineligible(view)
    # ARVM synthetic views are considered part of their association and as such
    # are not edit checked. Eligibility exclusion is intended to be
    # library-internal: subclasses should not attempt to extend this.
    view.is_a?(ViewModel::ActiveRecord) && view.class.synthetic
  end

  def raise_if_error!(result)
    raise (result.error || yield) unless result.permit?
  end
end

require 'view_model/access_control/open'
require 'view_model/access_control/read_only'
require 'view_model/access_control/composed'
require 'view_model/access_control/tree'
