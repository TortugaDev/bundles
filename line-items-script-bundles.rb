class Campaign
  def initialize(condition, *qualifiers)
    @condition = condition == :default ? :all? : (condition.to_s + '?').to_sym
    @qualifiers = PostCartAmountQualifier ? [] : [] rescue qualifiers.compact
    @line_item_selector = qualifiers.last unless @line_item_selector
    qualifiers.compact.each do |qualifier|
      is_multi_select = qualifier.instance_variable_get(:@conditions).is_a?(Array)
      if is_multi_select
        qualifier.instance_variable_get(:@conditions).each do |nested_q| 
          @post_amount_qualifier = nested_q if nested_q.is_a?(PostCartAmountQualifier)
          @qualifiers << qualifier
        end
      else
        @post_amount_qualifier = qualifier if qualifier.is_a?(PostCartAmountQualifier)
        @qualifiers << qualifier
      end
    end if @qualifiers.empty?
  end
  
  def qualifies?(cart)
    return true if @qualifiers.empty?
    @unmodified_line_items = cart.line_items.map do |item|
      new_item = item.dup
      new_item.instance_variables.each do |var|
        val = item.instance_variable_get(var)
        new_item.instance_variable_set(var, val.dup) if val.respond_to?(:dup)
      end
      new_item  
    end if @post_amount_qualifier
    @qualifiers.send(@condition) do |qualifier|
      is_selector = false
      if qualifier.is_a?(Selector) || qualifier.instance_variable_get(:@conditions).any? { |q| q.is_a?(Selector) }
        is_selector = true
      end rescue nil
      if is_selector
        raise "Missing line item match type" if @li_match_type.nil?
        cart.line_items.send(@li_match_type) { |item| qualifier.match?(item) }
      else
        qualifier.match?(cart, @line_item_selector)
      end
    end
  end

  def revert_changes(cart)
    cart.instance_variable_set(:@line_items, @unmodified_line_items)
  end
end

class BundleDiscount < Campaign
  def initialize(condition, customer_qualifier, cart_qualifier, discount, full_bundles_only, bundle_products)
    super(condition, customer_qualifier, cart_qualifier, nil)
    @bundle_products = bundle_products
    @discount = discount
    @full_bundles_only = full_bundles_only
    @split_items = []
    @bundle_items = []
  end
  
  def check_bundles(cart)
      bundled_items = @bundle_products.map do |bitem|
        quantity_required = bitem[:quantity].to_i
        qualifiers = bitem[:qualifiers]
        type = bitem[:type].to_sym
        case type
          when :ptype
            items = cart.line_items.select { |item| qualifiers.include?(item.variant.product.product_type) }
          when :ptag
            items = cart.line_items.select { |item| (qualifiers & item.variant.product.tags).length > 0 }
          when :pid
            qualifiers.map!(&:to_i)
            items = cart.line_items.select { |item| qualifiers.include?(item.variant.product.id) }
          when :vid
            qualifiers.map!(&:to_i)
            items = cart.line_items.select { |item| qualifiers.include?(item.variant.id) }
          when :vsku
            items = cart.line_items.select { |item| (qualifiers & item.variant.skus).length > 0 }
        end
        
        total_quantity = items.reduce(0) { |total, item| total + item.quantity }
        {
          has_all: total_quantity >= quantity_required,
          total_quantity: total_quantity,
          quantity_required: quantity_required,
          total_possible: (total_quantity / quantity_required).to_i,
          items: items
        }
      end
      
      max_bundle_count = bundled_items.map{ |bundle| bundle[:total_possible] }.min if @full_bundles_only
      if bundled_items.all? { |item| item[:has_all] }
        if @full_bundles_only
          bundled_items.each do |bundle|
            bundle_quantity = bundle[:quantity_required] * max_bundle_count
            split_out_extra_quantity(cart, bundle[:items], bundle[:total_quantity], bundle_quantity)
          end
        else
          bundled_items.each do |bundle|
            bundle[:items].each do |item| 
              @bundle_items << item 
              cart.line_items.delete(item)
            end
          end
        end
        return true
      end
      false
  end
  
  def split_out_extra_quantity(cart, items, total_quantity, quantity_required)
    items_to_split = quantity_required
    items.each do |item|
      break if items_to_split == 0
      if item.quantity > items_to_split
        @bundle_items << item.split({take: items_to_split})
        @split_items << item
        items_to_split = 0
      else
        @bundle_items << item
        split_quantity = item.quantity
        items_to_split -= split_quantity
      end
      cart.line_items.delete(item)
    end
    cart.line_items.concat(@split_items)
    @split_items.clear
  end
  
  def run(cart)
    raise "Campaign requires a discount" unless @discount
    return unless qualifies?(cart)
    
    if check_bundles(cart)
      @bundle_items.each { |item| @discount.apply(item) }
    end
    @bundle_items.reverse.each { |item| cart.line_items.prepend(item) }
    revert_changes(cart) unless @post_amount_qualifier.nil? || @post_amount_qualifier.match?(cart)
  end
end

class AndSelector
  def initialize(*conditions)
    @conditions = conditions.compact
  end

  def match?(item, selector = nil)
    @conditions.all? do |condition|
      if selector
        condition.match?(item, selector)
      else
        condition.match?(item)
      end
    end
  end
end

class Qualifier
  def partial_match(match_type, item_info, possible_matches)
    match_type = (match_type.to_s + '?').to_sym
    if item_info.kind_of?(Array)
      possible_matches.any? do |possibility|
        item_info.any? do |search|
          search.send(match_type, possibility)
        end
      end
    else
      possible_matches.any? do |possibility|
        item_info.send(match_type, possibility)
      end
    end
  end

  def compare_amounts(compare, comparison_type, compare_to)
    case comparison_type
      when :greater_than
        return compare > compare_to
      when :greater_than_or_equal
        return compare >= compare_to
      when :less_than
        return compare < compare_to
      when :less_than_or_equal
        return compare <= compare_to
      when :equal_to
        return compare == compare_to
      else
        raise "Invalid comparison type"
    end
  end
end

class ExcludeDiscountCodes < Qualifier
  def initialize(behaviour, message)
    @reject = behaviour == :apply_script
    @message = message == "" ? "Discount codes cannot be used with this offer" : message
  end
  
  def match?(cart, selector = nil)
    cart.discount_code.nil? || @reject && cart.discount_code.reject({message: @message})
  end
end

class FixedItemDiscount
  def initialize(amount, message)
    @amount = Money.new(cents: amount * 100)
    @message = message
  end

  def apply(line_item)
    per_item_price = line_item.variant.price
    per_item_discount = [(@amount - per_item_price), @amount].max
    discount_to_apply = [(per_item_discount * line_item.quantity), line_item.line_price].min
    line_item.change_line_price(line_item.line_price - discount_to_apply, {message: @message})
  end
end

CAMPAIGNS = [
  BundleDiscount.new(
    :any,
    nil,
    AndSelector.new(
      ExcludeDiscountCodes.new(
        :apply_script,
        "Unable to add discount code with bundle discount"
      ),
      nil,
      nil
    ),
    FixedItemDiscount.new(
      12,
      "Saved 10% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597193"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32446165257"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32082389897"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32083873353"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32084053065"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    AndSelector.new(
      ExcludeDiscountCodes.new(
        :apply_script,
        "Unable to add discount code with bundle discount"
      ),
      nil,
      nil
    ),
    FixedItemDiscount.new(
      11,
      "Saved 10% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597257"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32446165257"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32082389897"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32083873353"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32084053065"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      20,
      "Saved 10% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597193"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32446165257"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      20,
      "Saved 10% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597257"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32446165257"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      20,
      "Saved 10% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597193","32082389897"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      23,
      "Saved 13% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597257","32082389897"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      15,
      "Saved 8% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597193"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32083873353"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      15,
      "Saved 8% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["26900597257"], :quantity => "1"},	{:type => "vid", :qualifiers => ["32083873353"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      36,
      "Saved 15% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["40356841481"], :quantity => "1"},	{:type => "vid", :qualifiers => ["42839855561"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      5,
      "Saved 3% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["748029476873"], :quantity => "1"},	{:type => "vid", :qualifiers => ["2161629397001"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      8,
      "Saved 6% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["748029476873"], :quantity => "1"},	{:type => "vid", :qualifiers => ["2161639587849"], :quantity => "1"}]
  ),
  BundleDiscount.new(
    :all,
    nil,
    nil,
    FixedItemDiscount.new(
      5,
      "Saved 4% with bundle pricing"
    ),
    true,
    [{:type => "vid", :qualifiers => ["2432430080009"], :quantity => "1"},	{:type => "vid", :qualifiers => ["2161629397001"], :quantity => "1"}]
  ),
].freeze

CAMPAIGNS.each do |campaign|
  campaign.run(Input.cart)
end

Output.cart = Input.cart
