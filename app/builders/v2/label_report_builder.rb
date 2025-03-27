class V2::LabelReportBuilder
  include DateRangeHelper
  include ReportHelper
  attr_reader :account, :params

  def initialize(account, params)
    @account = account
    @params = params

    timezone_offset = (params[:timezone_offset] || 0).to_f
    @timezone = ActiveSupport::TimeZone[timezone_offset]&.name
  end

  def build
    labels = account.labels.to_a
    return [] if labels.empty?

    conversation_filter = build_conversation_filter
    use_business_hours = ActiveModel::Type::Boolean.new.cast(params[:business_hours])

    conversation_counts = fetch_conversation_counts(conversation_filter)
    resolved_counts = fetch_resolved_counts(conversation_filter)
    resolution_metrics = fetch_metrics(conversation_filter, 'conversation_resolved', use_business_hours)
    first_response_metrics = fetch_metrics(conversation_filter, 'first_response', use_business_hours)

    # Format the report data
    labels.map do |label|
      {
        id: label.id,
        name: label.title,
        conversations_count: conversation_counts[label.title] || 0,
        avg_resolution_time: resolution_metrics[label.title] || 0,
        avg_first_response_time: first_response_metrics[label.title] || 0,
        resolved_conversations_count: resolved_counts[label.title] || 0
      }
    end
  end

  private

  def build_conversation_filter
    conversation_filter = { account_id: account.id }
    conversation_filter[:created_at] = range if range.present?

    conversation_filter
  end

  def fetch_conversation_counts(conversation_filter)
    fetch_counts(conversation_filter)
  end

  def fetch_resolved_counts(conversation_filter)
    fetch_counts(conversation_filter.merge(status: :resolved))
  end

  def fetch_counts(conversation_filter)
    ActsAsTaggableOn::Tagging
      .joins('INNER JOIN conversations ON taggings.taggable_id = conversations.id')
      .joins('INNER JOIN tags ON taggings.tag_id = tags.id')
      .where(
        taggable_type: 'Conversation',
        context: 'labels',
        conversations: conversation_filter
      )
      .select('tags.name, COUNT(taggings.*) AS count')
      .group('tags.name')
      .each_with_object({}) { |record, hash| hash[record.name] = record.count }
  end

  def fetch_metrics(conversation_filter, event_name, use_business_hours)
    ReportingEvent
      .joins('INNER JOIN conversations ON reporting_events.conversation_id = conversations.id')
      .joins('INNER JOIN taggings ON taggings.taggable_id = conversations.id')
      .joins('INNER JOIN tags ON taggings.tag_id = tags.id')
      .where(
        conversations: conversation_filter,
        name: event_name,
        taggings: { taggable_type: 'Conversation', context: 'labels' }
      )
      .group('tags.name')
      .order('tags.name')
      .select(
        'tags.name',
        use_business_hours ? 'AVG(reporting_events.value_in_business_hours) as avg_value' : 'AVG(reporting_events.value) as avg_value'
      )
      .each_with_object({}) { |record, hash| hash[record.name] = record.avg_value.to_f }
  end
end
