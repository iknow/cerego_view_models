require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::HasManyThroughTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_many :parents_tags, dependent: :destroy, inverse_of: :parent
      end

      define_viewmodel do
        attributes :name
        association :tags, shared: true, through: :parents_tags, through_order_attr: :position
        include TrivialAccessControl
      end
    end

    build_viewmodel(:Tag) do
      define_schema do |t|
        t.string :name

      end

      define_model do
        has_many :parents_tag, dependent: :destroy, inverse_of: :tag
      end

      define_viewmodel do
        attributes :name

        include TrivialAccessControl
      end
    end


    build_viewmodel(:ParentsTag) do
      define_schema do |t|
        t.references :parent, foreign_key: true
        t.references :tag,    foreign_key: true
        t.float      :position
      end

      define_model do
        belongs_to :parent
        belongs_to :tag
        # TODO list membership?
      end

      no_viewmodel
    end
  end

  private def context_with(*args)
    Views::Parent.new_serialize_context(include: args)
  end

  def setup
    @tag1, @tag2, @tag3 = (1..3).map { |x| Tag.create(name: "tag#{x}") }

    @parent1 = Parent.create(name: 'p1',
                             parents_tags: [ParentsTag.new(tag: @tag1, position: 1.0),
                                            ParentsTag.new(tag: @tag2, position: 2.0)])

    @parent2 = Parent.create(name: 'p2',
                             parents_tags: [ParentsTag.new(tag: @tag3, position: 1.0),
                                            ParentsTag.new(tag: @tag3, position: 2.0),
                                            ParentsTag.new(tag: @tag3, position: 3.0)])

    super
  end

  def test_eager_includes
    includes = Views::Parent.eager_includes(serialize_context: context_with(:tags))
    assert_equal({ 'parents_tags' => { 'tag' => {} } }, includes)
  end

  def test_association_dependencies
    skip("wip")
    # TODO not part of ARVM; but depends on the particular context from #before_all
    # If we refactor out the contexts from their tests, this should go in another test file.

     root_updates, ref_updates = ActiveRecordViewModel::UpdateData.parse_hashes([{'_type' => 'Parent'}])
     assert_equal({},
                  root_updates.first.association_dependencies(ref_updates),
                  'nothing loaded by default')

    root_updates, ref_updates = ActiveRecordViewModel::UpdateData.parse_hashes([{'_type' => 'Parent',
                                                                                 'tags' => [{'_ref' => 'r1'}]}],
                                                                               {'r1' => {'_type' => 'Tag'}})
    puts "#{root_updates.inspect}"

    assert_equal({ 'parents_tags' => { 'tag' => {} } },
                 root_updates.first.association_dependencies(ref_updates),
                 'mentioning tags causes tag loading via through associaton')
  end

  def test_roundtrip
    # Objects are serialized to a view and deserialized, and should not be different when complete.

    alter_by_view!(Views::Parent, @parent1, serialize_context: context_with(:tags)) {}
    assert_equal('p1', @parent1.name)
    assert_equal([@tag1, @tag2], @parent1.parents_tags.order(:position).map(&:tag))

    alter_by_view!(Views::Parent, @parent2, serialize_context: context_with(:tags)) {}
    assert_equal('p2', @parent2.name)
    assert_equal([@tag3, @tag3, @tag3], @parent2.parents_tags.order(:position).map(&:tag))
  end

  def test_serialize
    view, refs = serialize_with_references(Views::Parent.new(@parent1),
                                           serialize_context: context_with(:tags))

    tag_data = view['tags'].map { |hash| refs[hash['_ref']] }
    assert_equal([{ 'id' => @tag1.id, '_type' => 'Tag', 'name' => 'tag1' },
                  { 'id' => @tag2.id, '_type' => 'Tag', 'name' => 'tag2' }],
                 tag_data)
  end

  def test_create_has_many_through
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      refs.delete_if { |_, ref_hash| ref_hash['_type'] == 'Tag' }
      refs['t1'] = { '_type' => 'Tag', 'name' => 'new tag1' }
      refs['t2'] = { '_type' => 'Tag', 'name' => 'new tag2' }
      view['tags'] = [{ '_ref' => 't1' }, { '_ref' => 't2' }]
    end

    new_tag1, new_tag2 = Tag.where(name: ['new tag1', 'new tag2'])

    refute_nil(new_tag1, 'new tag 1 created')
    refute_nil(new_tag2, 'new tag 2 created')

    assert_equal([new_tag1, new_tag2], @parent1.parents_tags.order(:position).map(&:tag),
                 'database state updated')
  end

  def test_delete
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      refs.clear
      view['tags'] = []
    end
    assert_equal([], @parent1.parents_tags)
  end

  def test_reordering
    alter_by_view!(Views::Parent, @parent1, serialize_context: context_with(:tags)) do |view, refs|
      view['tags'].reverse!
    end
    assert_equal([@tag2, @tag1],
                 @parent1.parents_tags.order(:position).map(&:tag))
  end


  def test_reordering_multi
    alter_by_view!(Views::Parent, @parent2, serialize_context: context_with(:tags)) do |view, refs|
      view['tags'].reverse!
    end
    assert_equal([@tag3, @tag3, @tag3],
                 @parent2.parents_tags.order(:position).map(&:tag))
  end
end