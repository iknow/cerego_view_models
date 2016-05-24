require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::BelongsToTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  module WithLabel
    def before_all
      super

      build_viewmodel(:Label) do
        define_schema do |t|
          t.string :text
        end

        define_model do
          has_one :parent, inverse_of: :label
        end

        define_viewmodel do
          attributes :text
          include TrivialAccessControl
        end
      end
    end
  end

  module WithParent
    def before_all
      super

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
          t.references :label, foreign_key: true
        end

        define_model do
          belongs_to :label, inverse_of: :parent, dependent: :destroy
        end

        define_viewmodel do
          attributes   :name
          associations :label
          include TrivialAccessControl
        end
      end
    end
  end

  module WithOwner
    def before_all
      super

      build_viewmodel(:Owner) do
        define_schema do |t|
          t.integer :deleted_id
          t.integer :ignored_id
        end

        define_model do
          belongs_to :deleted, class_name: Label.name, dependent: :delete
          belongs_to :ignored, class_name: Label.name
        end

        define_viewmodel do
          associations :deleted, :ignored
          include TrivialAccessControl
        end
      end
    end
  end

  include WithLabel
  include WithParent

  def setup
    super

    # TODO make a `has_list?` that allows a parent to set all children as an array
    @parent1 = Parent.new(name: "p1",
                          label: Label.new(text: "p1l"))
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          label: Label.new(text: "p2l"))

    @parent2.save!

    enable_logging!
  end

  def test_serialize_view
    view, _refs = serialize_with_references(Views::Parent.new(@parent1))

    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "label" => { "_type" => "Label",
                                "id" => @parent1.label.id,
                                "text" => @parent1.label.text },
                 },
                 view)
  end

  def test_loading_batching
    log_queries do
      serialize(Views::Parent.load)
    end

    assert_equal(['Parent Load', 'Label Load'],
                 logged_load_queries)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "label"    => { "_type" => "Label", "text" => "l" },
    }

    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.label.present?)
    assert_equal("l", p.label.text)
  end

  def test_create_belongs_to_nil
    view = { '_type' => 'Parent', 'name' => 'p', 'label' => nil }
    pv = Views::Parent.deserialize_from_view(view)
    assert_nil(pv.model.label)
  end

  def test_belongs_to_create
    @parent1.update(label: nil)

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
  end

  def test_belongs_to_replace
    old_label = @parent1.label

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
    assert(Label.where(id: old_label).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    set_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = nil
      p2['label'] = update_hash_for(Views::Label, old_p1_label)
    end

    assert(@parent1.label.blank?, 'l1 label reference removed')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
    assert(Label.where(id: old_p2_label).blank?, 'p2 old label deleted')
  end

  def test_belongs_to_move_and_replace_from_outside_tree
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    ex = assert_raises(ViewModel::DeserializationError) do
      set_by_view!(Views::Parent, @parent2) do |p2, refs|
        p2['label'] = update_hash_for(Views::Label, old_p1_label)
      end
    end

    # For now, we don't allow moving unless the pointer is from child to parent,
    # as it's more involved to safely resolve the old parent in the other
    # direction.
    assert_match(/Cannot resolve previous parents for the following referenced viewmodels/, ex.message)
  end

  def test_belongs_to_swap
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = update_hash_for(Views::Label, old_p2_label)
      p2['label'] = update_hash_for(Views::Label, old_p1_label)
    end

    assert_equal(old_p2_label, @parent1.label, 'p1 has label from p2')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
  end

  def test_implicit_release_invalid_belongs_to
    taken_label_ref = update_hash_for(Views::Label, @parent1.label)
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(
        [{ '_type' => 'Parent',
           'name'  => 'newp',
           'label' => taken_label_ref }])
    end

    assert_match(/Cannot resolve previous parents/, ex.message,
                 'belongs_to does not infer previous parents')
  end

  class GCTests < ActiveSupport::TestCase
    include ARVMTestUtilities
    include WithLabel
    include WithOwner
    include WithParent

    # test belongs_to garbage collection - dependent: delete_all
    def test_gc_dependent_delete_all
      owner = Owner.create(deleted: Label.new(text: 'one'))
      old_label = owner.deleted

      alter_by_view!(Views::Owner, owner) do |ov, refs|
        ov['deleted'] = { '_type' => 'Label', 'text' => 'two' }
      end

      assert_equal('two', owner.deleted.text)
      refute_equal(old_label, owner.deleted)
      assert(Label.where(id: old_label.id).blank?)
    end

    def test_no_gc_dependent_ignore
      owner = Owner.create(ignored: Label.new(text: "one"))
      old_label = owner.ignored

      alter_by_view!(Views::Owner, owner) do |ov, refs|
        ov['ignored'] = { '_type' => 'Label', 'text' => 'two' }
      end
      assert_equal('two', owner.ignored.text)
      refute_equal(old_label, owner.ignored)
      assert_equal(1, Label.where(id: old_label.id).count)
    end
  end

  class RenamedTest < ActiveSupport::TestCase
    include ARVMTestUtilities
    include WithLabel

    def before_all
      super

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
          t.references :label, foreign_key: true
        end

        define_model do
          belongs_to :label, inverse_of: :parent, dependent: :destroy
        end

        define_viewmodel do
          attributes :name
          association :label, as: :something_else
          include TrivialAccessControl
        end
      end
    end

    def setup
      super

      @parent = Parent.create(name: 'p1', label: Label.new(text: 'l1'))

      enable_logging!
    end

    def test_renamed_roundtrip
      alter_by_view!(Views::Parent, @parent) do |view, refs|
        assert_equal({ 'id'    => @parent.label.id,
                       '_type' => 'Label',
                       'text'  => 'l1'},
                     view['something_else'])
        view['something_else']['text'] = 'new l1 text'
      end
      assert_equal('new l1 text', @parent.label.text)
    end
  end

end
