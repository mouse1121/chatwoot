require 'rails_helper'

describe ConversationFinder do
  subject(:conversation_finder) { described_class.new(user_1, params) }

  let!(:account) { create(:account) }
  let!(:user_1) { create(:user, account: account) }
  let!(:user_2) { create(:user, account: account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:contact_inbox) { create(:contact_inbox, inbox: inbox, source_id: 'testing_source_id') }
  let!(:restricted_inbox) { create(:inbox, account: account) }

  before do
    create(:inbox_member, user: user_1, inbox: inbox)
    create(:inbox_member, user: user_2, inbox: inbox)
    create(:conversation, account: account, inbox: inbox, assignee: user_1)
    create(:conversation, account: account, inbox: inbox, assignee: user_1)
    create(:conversation, account: account, inbox: inbox, assignee: user_1, status: 'resolved')
    create(:conversation, account: account, inbox: inbox, assignee: user_2, contact_inbox: contact_inbox)
    # unassigned conversation
    create(:conversation, account: account, inbox: inbox)
    account.disable_features!('cache_meta_counts')
    Current.account = account
  end

  describe '#perform' do
    context 'with status' do
      let(:params) { { status: 'open', assignee_type: 'me' } }

      it 'filter conversations by status' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 2
      end
    end

    context 'with inbox' do
      let!(:restricted_conversation) { create(:conversation, account: account, inbox_id: restricted_inbox.id) }

      it 'returns conversation from any inbox if its admin' do
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(admin, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'returns conversation from inbox if agent is its member' do
        params = { inbox_id: restricted_inbox.id }
        create(:inbox_member, user: user_1, inbox: restricted_inbox)
        result = described_class.new(user_1, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'does not return conversations from inboxes where agent is not a member' do
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(user_1, params).perform

        expect(result[:conversations].map(&:id)).not_to include(restricted_conversation.id)
      end
    end

    context 'with assignee_type all' do
      let(:params) { { assignee_type: 'all' } }

      it 'filter conversations by assignee type all' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
      end
    end

    context 'with assignee_type unassigned' do
      let(:params) { { assignee_type: 'unassigned' } }

      it 'filter conversations by assignee type unassigned' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with status all' do
      let(:params) { { status: 'all' } }

      it 'returns all conversations' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 5
      end
    end

    context 'with assignee_type assigned' do
      let(:params) { { assignee_type: 'assigned' } }

      it 'filter conversations by assignee type assigned' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 3
      end

      it 'returns the correct meta' do
        result = conversation_finder.perform
        expect(result[:count]).to eq({
                                       mine_count: 2,
                                       assigned_count: 3,
                                       unassigned_count: 1,
                                       all_count: 4
                                     })
      end
    end

    context 'with team' do
      let(:team) { create(:team, account: account) }
      let(:params) { { team_id: team.id } }

      it 'filter conversations by team' do
        create(:conversation, account: account, inbox: inbox, team: team)
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with labels' do
      let(:params) { { labels: ['resolved'] } }

      it 'filter conversations by labels' do
        conversation = inbox.conversations.first
        conversation.update_labels('resolved')

        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with source_id' do
      let(:params) { { source_id: 'testing_source_id' } }

      it 'filter conversations by source id' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'without source' do
      let(:params) { {} }

      it 'returns conversations with any source' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
      end
    end

    context 'with updated_within' do
      let(:params) { { updated_within: 20, assignee_type: 'unassigned', sort_by: 'created_at_asc' } }

      it 'filters based on params, sort order but returns all conversations without pagination with in time range' do
        # value of updated_within is in seconds
        # write spec based on that
        conversations = create_list(:conversation, 50, account: account,
                                                       inbox: inbox, assignee: nil,
                                                       updated_at: Time.now.utc - 30.seconds,
                                                       created_at: Time.now.utc - 30.seconds)
        # update updated_at of 27 conversations to be with in 20 seconds
        conversations[0..27].each do |conversation|
          conversation.update(updated_at: Time.now.utc - 10.seconds)
        end
        result = conversation_finder.perform
        # pagination is not applied
        # filters are applied
        # modified conversations + 1 conversation created during set up
        expect(result[:conversations].length).to be 29
        # ensure that the conversations are sorted by created_at
        expect(result[:conversations].first.created_at).to be < result[:conversations].last.created_at
      end
    end

    context 'with pagination' do
      let(:params) { { status: 'open', assignee_type: 'me', page: 1 } }

      it 'returns paginated conversations' do
        create_list(:conversation, 50, account: account, inbox: inbox, assignee: user_1)
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 25
      end
    end

    context 'with unattended' do
      let(:params) { { status: 'open', assignee_type: 'me', conversation_type: 'unattended' } }

      it 'returns unattended conversations' do
        create(:conversation, account: account, first_reply_created_at: Time.now.utc, assignee: user_1) # attended_conversation
        create(:conversation, account: account, first_reply_created_at: nil, assignee: user_1) # unattended_conversation_no_first_reply
        create(:conversation, account: account, first_reply_created_at: Time.now.utc,
                              assignee: user_1, waiting_since: Time.now.utc) # unattended_conversation_waiting_since

        result = conversation_finder.perform
        expect(result[:conversations].length).to be 2
      end
    end

    describe 'caching behavior' do
      let(:params) { { status: 'open' } }
      let(:cache_key) { format(Redis::Alfred::CONVERSATION_COUNTS, inbox_ids: inbox.id, status: 'open') }

      before do
        account.enable_features!('cache_meta_counts')
      end

      context 'when should_cache? returns true' do
        before do
          Redis::Alfred.delete(cache_key) if cache_key
        end

        it 'caches the unassigned and all counts' do
          expect(Redis::Alfred).to receive(:setex).with(
            cache_key,
            [1, 4], # unassigned_count and all_count
            instance_of(Integer)
          )

          conversation_finder.perform
        end

        it 'uses cached counts on subsequent calls' do
          # First call should cache the counts
          first_result = conversation_finder.perform

          # Create a new conversation that shouldn't be counted due to caching
          create(:conversation, account: account, inbox: inbox)

          # Second call should use cached counts
          second_result = conversation_finder.perform

          expect(second_result[:count][:unassigned_count]).to eq(first_result[:count][:unassigned_count])
          expect(second_result[:count][:all_count]).to eq(first_result[:count][:all_count])
        end

        it 'always computes mine_count fresh' do
          # First call
          first_result = conversation_finder.perform

          # Create a new conversation assigned to user_1
          create(:conversation, account: account, inbox: inbox, assignee: user_1)

          # Second call should have updated mine_count
          second_result = conversation_finder.perform

          expect(second_result[:count][:mine_count]).to eq(first_result[:count][:mine_count] + 1)
        end
      end

      context 'when has_additional_filters? returns true' do
        let(:params) { { status: 'open', labels: ['test'] } }

        it 'does not use cache' do
          expect(Redis::Alfred).not_to receive(:get)
          expect(Redis::Alfred).not_to receive(:setex)

          conversation_finder.perform
        end
      end

      context 'when should_cache? returns false' do
        before do
          account.disable_features!('cache_meta_counts')
        end

        it 'does not use cache' do
          expect(Redis::Alfred).not_to receive(:get)
          expect(Redis::Alfred).not_to receive(:setex)

          conversation_finder.perform
        end
      end
    end
  end
end
