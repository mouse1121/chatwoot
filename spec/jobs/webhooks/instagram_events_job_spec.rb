require 'rails_helper'

describe Webhooks::InstagramEventsJob do
  subject(:instagram_webhook) { described_class }

  before do
    stub_request(:post, /graph.facebook.com/)
    stub_request(:get, 'https://www.example.com/test.jpeg')
      .to_return(status: 200, body: '', headers: {})
  end

  let!(:account) { create(:account) }
  let(:return_object) do
    { name: 'Jane',
      id: 'Sender-id-1',
      account_id: instagram_inbox.account_id,
      profile_pic: 'https://chatwoot-assets.local/sample.png',
      username: 'some_user_name' }
  end
  let!(:instagram_channel) { create(:channel_instagram_fb_page, account: account, instagram_id: 'instagram-message-id-123') }
  let!(:instagram_inbox) { create(:inbox, channel: instagram_channel, account: account, greeting_enabled: false) }
  let!(:instagram_direct_channel) { create(:channel_instagram, account: account, instagram_id: 'instagram-message-id-123') }
  let!(:instagram_direct_inbox) { create(:inbox, channel: instagram_direct_channel, account: account, greeting_enabled: false) }

  # Combined message events into one helper
  let(:message_events) do
    {
      dm: build(:instagram_message_create_event).with_indifferent_access,
      standby: build(:instagram_message_standby_event).with_indifferent_access,
      unsend: build(:instagram_message_unsend_event).with_indifferent_access,
      attachment: build(:instagram_message_attachment_event).with_indifferent_access,
      story_mention: build(:instagram_story_mention_event).with_indifferent_access,
      story_mention_echo: build(:instagram_story_mention_event_with_echo).with_indifferent_access,
      messaging_seen: build(:messaging_seen_event).with_indifferent_access,
      unsupported: build(:instagram_message_unsupported_event).with_indifferent_access
    }
  end

  describe '#perform' do
    context 'when handling messaging events for Instagram via Facebook page channel' do
      let(:fb_object) { double }

      before do
        instagram_direct_inbox.destroy
      end

      it 'creates incoming message in the instagram inbox' do
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_return(
          return_object.with_indifferent_access
        )
        instagram_webhook.perform_now(message_events[:dm][:entry])

        instagram_inbox.reload

        expect(instagram_inbox.contacts.count).to be 1
        expect(instagram_inbox.contacts.last.additional_attributes['social_instagram_user_name']).to eq 'some_user_name'
        expect(instagram_inbox.conversations.count).to be 1
        expect(instagram_inbox.messages.count).to be 1
        expect(instagram_inbox.messages.last.content_attributes['is_unsupported']).to be_nil
      end

      it 'creates standby message in the instagram inbox' do
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_return(
          return_object.with_indifferent_access
        )
        instagram_webhook.perform_now(message_events[:standby][:entry])

        instagram_inbox.reload

        expect(instagram_inbox.contacts.count).to be 1
        expect(instagram_inbox.contacts.last.additional_attributes['social_instagram_user_name']).to eq 'some_user_name'
        expect(instagram_inbox.conversations.count).to be 1
        expect(instagram_inbox.messages.count).to be 1

        message = instagram_inbox.messages.last
        expect(message.content).to eq('This is the first standby message from the customer, after 24 hours.')
      end

      it 'handle instagram unsend message event' do
        message = create(:message, inbox_id: instagram_inbox.id, source_id: 'message-id-to-delete')
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_return(
          {
            name: 'Jane',
            id: 'Sender-id-1',
            account_id: instagram_inbox.account_id,
            profile_pic: 'https://chatwoot-assets.local/sample.png'
          }.with_indifferent_access
        )
        message.attachments.new(file_type: :image, external_url: 'https://www.example.com/test.jpeg')

        expect(instagram_inbox.messages.count).to be 1

        instagram_webhook.perform_now(message_events[:unsend][:entry])

        expect(instagram_inbox.messages.last.content).to eq 'This message was deleted'
        expect(instagram_inbox.messages.last.deleted).to be true
        expect(instagram_inbox.messages.last.attachments.count).to be 0
        expect(instagram_inbox.messages.last.reload.deleted).to be true
      end

      it 'creates incoming message with attachments in the instagram inbox' do
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_return(
          return_object.with_indifferent_access
        )
        instagram_webhook.perform_now(message_events[:attachment][:entry])

        instagram_inbox.reload

        expect(instagram_inbox.contacts.count).to be 1
        expect(instagram_inbox.messages.count).to be 1
        expect(instagram_inbox.messages.last.attachments.count).to be 1
      end

      it 'creates incoming message with attachments in the instagram inbox for story mention' do
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_return(
          return_object.with_indifferent_access,
          { story:
            {
              mention: {
                link: 'https://www.example.com/test.jpeg',
                id: '17920786367196703'
              }
            },
            from: {
              username: 'Sender-id-1', id: 'Sender-id-1'
            },
            id: 'instagram-message-id-1234' }.with_indifferent_access
        )

        instagram_webhook.perform_now(message_events[:story_mention][:entry])

        instagram_inbox.reload

        expect(instagram_inbox.messages.count).to be 1
        expect(instagram_inbox.messages.last.attachments.count).to be 1

        attachment = instagram_inbox.messages.last.attachments.last
        expect(attachment.push_event_data[:data_url]).to eq(attachment.external_url)
      end

      it 'creates does not create contact or messages' do
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_raise(Koala::Facebook::ClientError)

        instagram_webhook.perform_now(message_events[:story_mention_echo][:entry])

        instagram_inbox.reload

        expect(instagram_inbox.contacts.count).to be 0
        expect(instagram_inbox.contact_inboxes.count).to be 0
        expect(instagram_inbox.messages.count).to be 0
      end

      it 'handle messaging_seen callback' do
        expect(Instagram::ReadStatusService).to receive(:new).with(params: message_events[:messaging_seen][:entry][0][:messaging][0],
                                                                   channel: instagram_inbox.channel).and_call_original
        instagram_webhook.perform_now(message_events[:messaging_seen][:entry])
      end

      it 'handles unsupported message' do
        allow(Koala::Facebook::API).to receive(:new).and_return(fb_object)
        allow(fb_object).to receive(:get_object).and_return(
          return_object.with_indifferent_access
        )

        instagram_webhook.perform_now(message_events[:unsupported][:entry])
        instagram_inbox.reload

        expect(instagram_inbox.contacts.count).to be 1
        expect(instagram_inbox.contacts.last.additional_attributes['social_instagram_user_name']).to eq 'some_user_name'
        expect(instagram_inbox.conversations.count).to be 1
        expect(instagram_inbox.messages.count).to be 1
        expect(instagram_inbox.messages.last.content_attributes['is_unsupported']).to be true
      end
    end

    context 'when handling messaging events for Instagram via Instagram direct channel' do
      before do
        instagram_direct_channel.update(access_token: 'valid_instagram_token')

        stub_request(:get, %r{https://graph.instagram.com/v22.0/Sender-id-1\?.*})
          .to_return(
            status: 200,
            body: {
              name: 'Jane',
              username: 'some_user_name',
              profile_pic: 'https://chatwoot-assets.local/sample.png',
              id: 'Sender-id-1',
              follower_count: 100,
              is_user_follow_business: true,
              is_business_follow_user: true,
              is_verified_user: false
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'creates incoming message in the instagram direct inbox' do
        instagram_webhook.perform_now(message_events[:dm][:entry])

        instagram_direct_inbox.reload

        expect(instagram_direct_inbox.contacts.count).to be 1
        expect(instagram_direct_inbox.contacts.last.additional_attributes['social_instagram_user_name']).to eq 'some_user_name'
        expect(instagram_direct_inbox.conversations.count).to be 1
        expect(instagram_direct_inbox.messages.count).to be 1
        expect(instagram_direct_inbox.messages.last.content_attributes['is_unsupported']).to be_nil
      end
    end
  end
end
