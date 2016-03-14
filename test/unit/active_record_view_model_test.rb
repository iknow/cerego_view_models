# -*- coding: utf-8 -*-

require "bundler/setup"
Bundler.require

require_relative "../helpers/test_models.rb"

require "minitest/autorun"
require 'minitest/unit'

require "byebug"




class ActiveRecordViewModelTest < ActiveSupport::TestCase

  def setup
    @parent1 = Parent.new(name:     "p1",
                          children: [Child.new(name: "p1c1"), Child.new(name: "p1c2"), Child.new(name: "p1c3")],
                          label:    Label.new(text: "p1l"),
                          target:   Target.new(text: "p1t"),
                          poly:     PolyOne.new(number: 1))
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          children: [Child.new(name: "p2c1"), Child.new(name: "p2c2")],
                          label: Label.new(text: "p2l"))
    @parent2.save!
  end

  def test_find
    parentview = ParentView.find(@parent1.id)
    assert_equal(@parent1, parentview.model)

    child = @parent1.children.first
    childview = parentview.find_associated(:children, child.id)
    assert_equal(child, childview.model)
  end

  def test_load
    parentviews = ParentView.load
    assert_equal(2, parentviews.size)

    h = parentviews.index_by(&:id)
    assert_equal(@parent1, h[@parent1.id].model)
    assert_equal(@parent2, h[@parent2.id].model)
  end

  def test_visibility
    parentview = ParentView.new(@parent1)

    assert_raises(ViewModel::SerializationError) do
      parentview.to_hash(can_view: false)
    end
  end

  def test_editability
    assert_raises(ViewModel::DeserializationError) do
      # create
      ParentView.deserialize_from_view({ "name" => "p" }, can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # edit
      v = ParentView.new(@parent1).to_hash.merge("name" => "p2")
      ParentView.deserialize_from_view(v, can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy
      ParentView.new(@parent1).destroy!(can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # append child
      ParentView.new(@parent1).deserialize_associated(:children, {"text" => "hi"}, can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # replace children
      ParentView.new(@parent1).deserialize_associated(:children, [{"text" => "hi"}], can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy child
      ParentView.new(@parent1).delete_associated(:target, TargetView.new(@parent1.target), can_edit: false)
    end
  end

  def test_serialize_view
    s = ParentView.new(@parent1)
    assert_equal(s.to_hash,
                 { "id"       => @parent1.id,
                   "name"     => @parent1.name,
                   "label"    => { "id" => @parent1.label.id, "text" => @parent1.label.text },
                   "target"   => { "id" => @parent1.target.id, "text" => @parent1.target.text, "label" => nil },
                   "poly_type" => @parent1.poly_type,
                   "poly"      => { "id" => @parent1.poly.id, "number" => @parent1.poly.number },
                   "children" => @parent1.children.map{|child| {"id" => child.id, "name" => child.name, "position" => child.position }}})
  end

  def test_eager_includes
    p = ParentView.eager_includes
    assert_equal({:children=>{}, :label=>{}, :target=>{:label=>{}}, :poly=>nil}, p)
  end

  def test_create_from_view
    view = {
      "name" => "p",
      "label" => { "text" => "l" },
      "target" => { "text" => "t" },
      "children" => [{ "name" => "c1" }, {"name" => "c2"}],
      "poly_type" => "PolyTwo",
      "poly" => { "text" => "pol" }
    }

    pv = ParentView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.label.present?)
    assert_equal("l", p.label.text)

    assert(p.target.present?)
    assert_equal("t", p.target.text)

    assert_equal(2, p.children.count)
    p.children.order(:id).each_with_index do |c, i|
      assert(!c.changed?)
      assert(!c.new_record?)
      assert_equal("c#{i + 1}", c.name)
    end

    assert(p.poly.present?)
    assert(p.poly.is_a?(PolyTwo))
    assert_equal("pol", p.poly.text)
  end

  def test_bad_single_association
    view = {
      "children" => nil
    }
    assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view(view)
    end
  end

  def test_bad_multiple_association
    view = {
      "target" => []
    }
    assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view(view)
    end
  end

  def test_create_without_polymorphic_type
   view = {
      "name" => "p",
      "poly" => { "text" => "pol" }
    }

    assert_raises(ViewModel::DeserializationError) do
     ParentView.deserialize_from_view(view)
    end
  end

  def test_edit_attribute_from_view
    view = ParentView.new(@parent1).to_hash

    view["name"] = "renamed"
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal("renamed", @parent1.name)
  end

  ### Test Associations
  ### has_many

  def test_has_many_empty_association
    #create
    view = { "name" => "p", "children" => [] }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model
    assert(p.children.blank?)

    # update
    h = pv.to_hash
    child = Child.new(name: "x")
    p.children << child
    p.save!

    ParentView.deserialize_from_view(h)
    p.reload
    assert(p.children.blank?)
    assert(Child.where(id: child.id).blank?)
  end

  def test_replace_has_many
    view = ParentView.new(@parent1).to_hash
    old_children = @parent1.children

    view["children"] = [{"name" => "new_child"}]
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(1, @parent1.children.size)
    old_children.each {|child| assert_not_equal(child, @parent1.children.first) }
    assert_equal("new_child", @parent1.children.first.name)
  end

  def test_edit_has_many
    old_children = @parent1.children.order(:position).to_a
    view = ParentView.new(@parent1).to_hash

    view["children"].shift
    view["children"] << { "name" => "c3" }
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(3, @parent1.children.size)
    tc1, tc2, tc3 = @parent1.children.order(:position)

    assert_equal(old_children[1], tc1)
    assert_equal(1, tc1.position)

    assert_equal(old_children[2], tc2)
    assert_equal(2, tc2.position)

    assert_equal("c3", tc3.name)
    assert_equal(3, tc3.position)

    assert(Child.where(id: old_children[0].id).blank?)
  end

  def test_edit_explicit_list_position
    old_children = @parent1.children.order(:position).to_a

    view = ParentView.new(@parent1).to_hash

    view["children"][0]["position"] = 2
    view["children"][1]["position"] = 1
    view["children"] << { "name" => "c3" }
    view["children"] << { "name" => "c4" }
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(5, @parent1.children.size)
    tc1, tc2, tc3, tc4, tc5 = @parent1.children.order(:position)
    assert_equal(old_children[1], tc1)
    assert_equal(old_children[0], tc2)
    assert_equal(old_children[2], tc3)
    assert_equal("c3", tc4.name)
    assert_equal("c4", tc5.name)
  end

  def test_edit_implicit_list_position
    old_children = @parent1.children.order(:position).to_a

    view = ParentView.new(@parent1).to_hash

    view["children"].each { |c| c.delete("position") }
    view["children"].reverse!
    view["children"].insert(1, { "name" => "c3" })

    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(4, @parent1.children.size)
    tc1, tc2, tc3, tc4 = @parent1.children.order(:position)

    assert_equal(old_children[2], tc1)
    assert_equal(1, tc1.position)

    assert_equal("c3", tc2.name)
    assert_equal(2, tc2.position)

    assert_equal(old_children[1], tc3)
    assert_equal(3, tc3.position)

    assert_equal(old_children[0], tc4)
    assert_equal(4, tc4.position)
  end

  def test_move_child_to_new
    child = @parent1.children[1]

    child_view = ChildView.new(child).to_hash

    view = { "name" => "new_p", "children" => [child_view, {"name" => "new"}]}
    pv = ParentView.deserialize_from_view(view)
    parent = pv.model

    # child should be removed from old parent and positions updated
    @parent1.reload
    assert_equal(2, @parent1.children.size)
    oc1, oc2 = @parent1.children.order(:position)
    assert_equal("p1c1", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("p1c3", oc2.name)
    assert_equal(2, oc2.position)

    # child should be added to new parent with valid position
    assert_equal(2, parent.children.size)
    nc1, nc2 = parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal("p1c2", nc1.name)
    assert_equal(1, nc1.position)
    assert_equal("new", nc2.name)
    assert_equal(2, nc2.position)
  end

  def test_move_child_to_existing
    child = @parent1.children[1]

    view = ParentView.new(@parent2).to_hash
    view["children"] << ChildView.new(child).to_hash

    ParentView.deserialize_from_view(view)

    @parent1.reload
    @parent2.reload

    # child should be removed from old parent and positions updated
    assert_equal(2, @parent1.children.size)
    oc1, oc2 = @parent1.children.order(:position)
    assert_equal("p1c1", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("p1c3", oc2.name)
    assert_equal(2, oc2.position)

    # child should be added to new parent with valid position
    assert_equal(3, @parent2.children.size)
    nc1, nc2, nc3 = @parent2.children.order(:position)

    assert_equal("p2c1", nc1.name)
    assert_equal(1, nc1.position)

    assert_equal("p2c2", nc2.name)
    assert_equal(2, nc2.position)

    assert_equal(child, nc3)
    assert_equal("p1c2", nc3.name)
    assert_equal(3, nc3.position)
  end

  def test_move_and_edit_child_to_new
    child = @parent1.children[1]


    child_view = ChildView.new(child).to_hash
    child_view["name"] = "changed"

    view = { "name" => "new_p", "children" => [child_view, {"name" => "new"}]}
    pv = ParentView.deserialize_from_view(view)
    parent = pv.model

    # child should be removed from old parent and positions updated
    @parent1.reload
    assert_equal(2, @parent1.children.size)
    oc1, oc2 = @parent1.children.order(:position)
    assert_equal("p1c1", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("p1c3", oc2.name)
    assert_equal(2, oc2.position)

    # child should be added to new parent with valid position
    assert_equal(2, parent.children.size)
    nc1, nc2 = parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal("changed", nc1.name)
    assert_equal(1, nc1.position)
    assert_equal("new", nc2.name)
    assert_equal(2, nc2.position)
  end

  def test_move_and_edit_child_to_existing
    old_child = @parent1.children[1]

    old_child_view = ChildView.new(old_child).to_hash
    old_child_view["name"] = "changed"
    view = ParentView.new(@parent2).to_hash
    view["children"] << old_child_view

    ParentView.deserialize_from_view(view)

    @parent1.reload
    @parent2.reload

    # child should be removed from old parent and positions updated
    assert_equal(2, @parent1.children.size)
    oc1, oc2 = @parent1.children.order(:position)

    assert_equal("p1c1", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("p1c3", oc2.name)
    assert_equal(2, oc2.position)

    # child should be added to new parent with valid position
    assert_equal(3, @parent2.children.size)
    nc1, nc2, nc3 = @parent2.children.order(:position)
    assert_equal("p2c1", nc1.name)
    assert_equal(1, nc1.position)

    assert_equal("p2c1", nc1.name)
    assert_equal(2, nc2.position)

    assert_equal(old_child, nc3)
    assert_equal("changed", nc3.name)
    assert_equal(3, nc3.position)
  end

  ### belongs_to

  def test_belongs_to_nil_association
    # create
    view = { "name" => "p", "label" => nil }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model
    assert_nil(p.label)

    # update
    h = pv.to_hash
    p.label = label = Label.new(text: "hello")
    p.save!

    ParentView.deserialize_from_view(h)
    p.reload
    assert_nil(p.label)
    assert(Label.where(id: label.id).blank?)
  end

  def test_belongs_to_create
    @parent1.label = nil
    @parent1.save!
    @parent1.reload

    view = ParentView.new(@parent1).to_hash
    view["label"] = { "text" => "cheese" }

    ParentView.deserialize_from_view(view)
    @parent1.reload

    assert(@parent1.label.present?)
    assert_equal("cheese", @parent1.label.text)
  end

  def test_belongs_to_replace
    old_label = @parent1.label

    view = ParentView.new(@parent1).to_hash
    view["label"] = { "text" => "cheese" }

    ParentView.deserialize_from_view(view)
    @parent1.reload

    assert(@parent1.label.present?)
    assert_equal("cheese", @parent1.label.text)
    assert(Label.where(id: old_label).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p2_label = @parent2.label

    v1 = ParentView.new(@parent1).to_hash
    v2 = ParentView.new(@parent2).to_hash

    # move l1 to p2
    # l2 should be garbage collected
    # p1 should now have no label

    v2["label"] = v1["label"]

    ParentView.deserialize_from_view(v2)

    @parent1.reload
    @parent2.reload

    assert(@parent1.label.blank?)
    assert(@parent2.label.present?)
    assert_equal("p1l", @parent2.label.text)
    assert(Label.where(id: old_p2_label).blank?)
  end

  def test_belongs_to_build_new_association
    old_label = @parent1.label

    ParentView.new(@parent1).deserialize_associated(:label, { "text" => "l2" })

    @parent1.reload

    assert(Label.where(id: old_label.id).blank?)
    assert_equal("l2", @parent1.label.text)
  end

  def test_belongs_to_update_existing_association
    label = @parent1.label
    lv = LabelView.new(label).to_hash
    lv["text"] = "renamed"

    ParentView.new(@parent1).deserialize_associated(:label, lv)

    @parent1.reload

    assert_equal(label, @parent1.label)
    assert_equal("renamed", @parent1.label.text)
  end

  def test_belongs_to_move_existing_association
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    ParentView.new(@parent2).deserialize_associated("label", { "id" => old_p1_label.id })

    @parent1.reload
    @parent2.reload

    assert(@parent1.label.blank?)
    assert(Label.where(id: old_p2_label.id).blank?)

    assert_equal(old_p1_label, @parent2.label)
    assert_equal("p1l", @parent2.label.text)
  end

  # test belongs_to garbage collection - dependent: delete_all
  def test_gc_dependent_delete_all
    o = Owner.create(deleted: Label.new(text: "one"))
    l = o.deleted

    ov = OwnerView.new(o).to_hash
    ov["deleted"] = { "text" => "two" }
    OwnerView.deserialize_from_view(ov)

    o.reload

    assert_equal("two", o.deleted.text)
    assert(l != o.deleted)
    assert(Label.where(id: l.id).blank?)
  end

  def test_no_gc_dependent_ignore
    o = Owner.create(ignored: Label.new(text: "one"))
    l = o.ignored

    ov = OwnerView.new(o).to_hash
    ov["ignored"] = { "text" => "two" }
    OwnerView.deserialize_from_view(ov)

    o.reload

    assert_equal("two", o.ignored.text)
    assert(l != o.ignored)
    assert_equal(1, Label.where(id: l.id).count)
  end

  ### has_one

  def test_has_one_nil_association
    # create
    view = { "name" => "p", "target" => nil }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model
    assert_nil(p.target)

    # update
    h = pv.to_hash
    p.target = target = Target.new
    p.save!

    ParentView.deserialize_from_view(h)
    p.reload
    assert_nil(p.target)
    assert(Target.where(id: target.id).blank?)
  end

  def test_has_one_create
    p = Parent.create(name: "p")

    view = ParentView.new(p).to_hash
    view["target"] = { "text" => "t" }

    ParentView.deserialize_from_view(view)
    p.reload

    assert(p.target.present?)
    assert_equal("t", p.target.text)
  end

  def test_has_one_move_and_replace
    @parent2.create_target(text: "p2t")

    t1 = @parent1.target
    t2 = @parent2.target

    v1 = ParentView.new(@parent1).to_hash
    v2 = ParentView.new(@parent2).to_hash

    v2["target"] = v1["target"]

    ParentView.deserialize_from_view(v2)
    @parent1.reload
    @parent2.reload

    assert(@parent1.target.blank?)
    assert(@parent2.target.present?)
    assert_equal(t1.text, @parent2.target.text)

    assert(Target.where(id: t2).blank?)
  end

  def test_has_one_build_new_association
    old_target = @parent1.target
    ParentView.new(@parent1).deserialize_associated(:target, { "text" => "new" })

    @parent1.reload

    assert(Target.where(id: old_target.id).blank?)
    assert_equal("new", @parent1.target.text)
  end

  def test_has_one_update_existing_association
    t = @parent1.target
    tv = TargetView.new(t).to_hash
    tv["text"] = "renamed"

    ParentView.new(@parent1).deserialize_associated(:target, tv)

    @parent1.reload

    assert_equal(t, @parent1.target)
    assert_equal("renamed", @parent1.target.text)
  end

  def test_has_one_move_existing_association
    @parent2.create_target(text: "p2t")
    t1 = @parent1.target
    t2 = @parent2.target

    ParentView.new(@parent2).deserialize_associated("target", { "id" => t1.id })

    @parent1.reload
    @parent2.reload

    assert(@parent1.target.blank?)
    assert(Target.where(id: t2.id).blank?)

    assert_equal(t1, @parent2.target)
    assert_equal("p1t", @parent2.target.text)
  end

  # test building extra child in association
  def test_has_many_build_new_association
    ParentView.new(@parent1).deserialize_associated(:children, { "name" => "new" })

    @parent1.reload

    assert_equal(4, @parent1.children.size)
    lc = @parent1.children.order(:position).last
    assert_equal("new", lc.name)
  end

  def test_has_many_build_new_association_with_explicit_position
    ParentView.new(@parent2).deserialize_associated(:children, { "name" => "new", "position" => 2 })

    @parent2.reload

    children = @parent2.children.order(:position)

    assert_equal(3, children.size)
    assert_equal(["p2c1", "new",  "p2c2"], children.map(&:name))
    assert_equal([1, 2, 3], children.map(&:position))
  end

  def test_has_many_update_existing_association
   child = @parent1.children[1]

    cv = ChildView.new(child).to_hash
    cv["name"] = "newname"

    ParentView.new(@parent1).deserialize_associated(:children, cv)

    @parent1.reload

    assert_equal(3, @parent1.children.size)
    c1, c2, c3 = @parent1.children.order(:position)
    assert_equal("p1c1", c1.name)

    assert_equal(child, c2)
    assert_equal("newname", c2.name)

    assert_equal("p1c3", c3.name)
  end

  def test_has_many_move_existing_association
    p1c2 = @parent1.children[1]
    assert_equal(2, p1c2.position)

    ParentView.new(@parent2).deserialize_associated("children", { "id" => p1c2.id })

    @parent1.reload
    @parent2.reload

    p1c = @parent1.children.order(:position)
    assert_equal(2, p1c.size)
    assert_equal(["p1c1", "p1c3"], p1c.map(&:name))

    p2c = @parent2.children.order(:position)
    assert_equal(3, p2c.size)
    assert_equal(["p2c1", "p2c2", "p1c2"], p2c.map(&:name))
    assert_equal(p1c2, p2c[2])
    assert_equal(3, p2c[2].position)
  end

  def test_delete_association
    p1c2 = @parent1.children[1]

    ParentView.new(@parent1).delete_associated("children", ChildView.new(p1c2))
    @parent1.reload

    assert_equal(2, @parent1.children.size)
    assert_equal(["p1c1", "p1c3"], @parent1.children.map(&:name))
    assert_equal([1, 2], @parent1.children.map(&:position))

    assert(Child.where(id: p1c2).blank?)
  end
end
