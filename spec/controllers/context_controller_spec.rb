# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../sharding_spec_helper')

describe ContextController do
  before :once do
    course_with_teacher(active_all: true)
    student_in_course(active_all: true)
  end

  describe "GET 'roster'" do
    it 'requires authorization' do
      get 'roster', params: { course_id: @course.id }
      assert_unauthorized
    end

    it 'works when the context is a group in a course' do
      user_session(@student)
      @group = @course.groups.create!
      @group.add_user(@student, 'accepted')
      get 'roster', params: { group_id: @group.id }
      expect(assigns[:primary_users].each_value.first.collect(&:id)).to eq [@student.id]
      expect(assigns[:secondary_users].each_value.first.collect(&:id)).to match_array @course.admins
                                                                                             .map(&:id)
    end

    it 'only shows active group members to students' do
      active_student = user_factory
      @course.enroll_student(active_student).accept!
      inactive_student = user_factory
      @course.enroll_student(inactive_student).deactivate

      @group = @course.groups.create!
      [@student, active_student, inactive_student].each { |u| @group.add_user(u, 'accepted') }

      user_session(@student)
      get 'roster', params: { group_id: @group.id }
      expect(assigns[:primary_users].each_value.first.collect(&:id)).to match_array [
        @student.id,
        active_student.id
      ]
    end

    it 'only shows active course instructors to students' do
      active_teacher = user_factory
      @course.enroll_teacher(active_teacher).accept!
      inactive_teacher = user_factory
      @course.enroll_teacher(inactive_teacher).deactivate

      @group = @course.groups.create!
      @group.add_user(@student, 'accepted')

      user_session(@student)
      get 'roster', params: { group_id: @group.id }
      teacher_ids = assigns[:secondary_users].each_value.first.map(&:id)
      expect(teacher_ids & [active_teacher.id, inactive_teacher.id]).to eq [active_teacher.id]
    end

    it 'shows all group members to admins' do
      active_student = user_factory
      @course.enroll_student(active_student).accept!
      inactive_student = user_factory
      @course.enroll_student(inactive_student).deactivate

      @group = @course.groups.create!
      [@student, active_student, inactive_student].each { |u| @group.add_user(u, 'accepted') }
      user_session(@teacher)
      get 'roster', params: { group_id: @group.id }
      expect(assigns[:primary_users].each_value.first.collect(&:id)).to match_array [
        @student.id,
        active_student.id,
        inactive_student.id
      ]
    end

    it "redirects 'disabled', if disabled by the teacher" do
      user_session(@student)
      @course.update_attribute(
        :tab_configuration,
        [{ 'id' => Course::TAB_PEOPLE, 'hidden' => true }]
      )
      get 'roster', params: { course_id: @course.id }
      expect(response).to be_redirect
      expect(flash[:notice]).to match(/That page has been disabled/)
    end

    context 'student context cards' do
      it 'is always enabled for teachers' do
        %w[manage_students manage_admin_users].each do |perm|
          RoleOverride.manage_role_override(Account.default, teacher_role, perm, override: false)
        end
        user_session(@teacher)
        get :roster, params: { course_id: @course.id }
        expect(assigns[:js_env][:STUDENT_CONTEXT_CARDS_ENABLED]).to be true
      end

      it 'is always disabled for students' do
        user_session(@student)
        get :roster, params: { course_id: @course.id }
        expect(assigns[:js_env][:STUDENT_CONTEXT_CARDS_ENABLED]).to be_falsey
      end
    end
  end

  describe "GET 'roster_user'" do
    it 'requires authorization' do
      get 'roster_user', params: { course_id: @course.id, id: @user.id }
      assert_unauthorized
    end

    it 'assigns variables' do
      user_session(@teacher)
      @enrollment = @course.enroll_student(user_factory(active_all: true))
      @enrollment.accept!
      @student = @enrollment.user
      get 'roster_user', params: { course_id: @course.id, id: @student.id }
      expect(assigns[:membership]).not_to be_nil
      expect(assigns[:membership]).to eql(@enrollment)
      expect(assigns[:user]).not_to be_nil
      expect(assigns[:user]).to eql(@student)
      expect(assigns[:topics]).not_to be_nil
      expect(assigns[:messages]).not_to be_nil
    end

    describe 'across shards' do
      specs_require_sharding

      it 'allows merged users from other shards to be referenced' do
        user1 = user_model
        course1 = course_factory(active_all: true)
        course1.enroll_user(user1)

        @shard2.activate do
          @user2 = user_model
          @course2 = course_factory(active_all: true)
          @course2.enroll_user(@user2)
        end

        UserMerge.from(user1).into(@user2)

        admin = user_model
        Account.site_admin.account_users.create!(user: admin)
        user_session(admin)

        get 'roster_user', params: { course_id: course1.id, id: @user2.id }
        expect(response).to be_successful
      end
    end

    describe 'hide_sections_on_course_users_page setting is Off' do
      before :once do
        @student2 = student_in_course(course: @course, active_all: true).user
      end

      it 'sets js_env with hide sections setting to false' do
        @other_section = @course.course_sections.create! name: 'Other Section FRD'
        user_session(@student)
        get 'roster', params: { course_id: @course.id, id: @student.id }
        expect(assigns['js_env'][:course][:hideSectionsOnCourseUsersPage]).to be_falsey
      end

      it 'sets js_env with hide sections setting to true' do
        @course.hide_sections_on_course_users_page = true
        @course.save!
        @other_section = @course.course_sections.create! name: 'Other Section FRD'
        user_session(@student)
        get 'roster', params: { course_id: @course.id, id: @student.id }
        expect(assigns['js_env'][:course][:hideSectionsOnCourseUsersPage]).to be_truthy
      end
    end

    describe 'section visibility' do
      before :once do
        @other_section = @course.course_sections.create! name: 'Other Section FRD'
        @course.enroll_teacher(@teacher, section: @other_section, allow_multiple_enrollments: true)
               .accept!
        @other_student = user_factory
        @course.enroll_student(
          @other_student,
          section: @other_section, limit_privileges_to_course_section: true
        )
               .accept!
      end

      it 'prevents section-limited users from seeing users in other sections' do
        user_session(@student)
        get 'roster_user', params: { course_id: @course.id, id: @other_student.id }
        expect(response).to be_successful

        user_session(@other_student)
        get 'roster_user', params: { course_id: @course.id, id: @student.id }
        expect(response).to be_redirect
        expect(flash[:error]).to be_present
      end

      it 'limits enrollments by visibility for course default section' do
        user_session(@student)
        get 'roster_user', params: { course_id: @course.id, id: @teacher.id }
        expect(response).to be_successful
        expect(assigns[:enrollments].map(&:course_section_id)).to match_array(
          [@course.default_section.id, @other_section.id]
        )
      end

      it 'limits enrollments by visibility for other section' do
        user_session(@other_student)
        get 'roster_user', params: { course_id: @course.id, id: @teacher.id }
        expect(response).to be_successful
        expect(assigns[:enrollments].map(&:course_section_id)).to match_array([@other_section.id])
      end

      it 'lets admins see concluded students' do
        user_session(@teacher)
        @student.enrollments.first.complete!
        get 'roster_user', params: { course_id: @course.id, id: @student.id }
        expect(response).to be_successful
      end

      it 'lets admins see inactive students' do
        user_session(@teacher)
        @student.enrollments.first.deactivate
        get 'roster_user', params: { course_id: @course.id, id: @student.id }
        expect(response).to be_successful
      end

      it 'does not let students see inactive students' do
        another_student = user_factory
        @course.enroll_student(another_student, section: @course.default_section).accept!
        user_session(another_student)

        @student.enrollments.first.deactivate

        get 'roster_user', params: { course_id: @course.id, id: @student.id }
        expect(response).to_not be_successful
      end

      context 'hide course sections from students feature enabled' do
        it 'sets js_env with hide sections setting to true for roster_user' do
          @course.hide_sections_on_course_users_page = true
          @course.save!
          @other_section = @course.course_sections.create! name: 'Other Section FRD'
          user_session(@student)
          get 'roster_user', params: { course_id: @course.id, id: @teacher.id }
          expect(assigns['js_env'][:course][:hideSectionsOnCourseUsersPage]).to be_truthy
        end

        it 'sets js_env with hide sections setting to false for roster_user' do
          @course.hide_sections_on_course_users_page = false
          @course.save!
          @other_section = @course.course_sections.create! name: 'Other Section FRD'
          user_session(@student)
          get 'roster_user', params: { course_id: @course.id, id: @teacher.id }
          expect(assigns['js_env'][:course][:hideSectionsOnCourseUsersPage]).to be_falsey
        end
      end
    end

    context 'profiles enabled' do
      it 'does not show the dummy course as common' do
        account_admin_user
        course_with_student(active_all: true)

        account = Account.default
        account.settings = { enable_profiles: true }
        account.save!
        expect(account.enable_profiles?).to be_truthy
        Course.ensure_dummy_course

        user_session(@admin)
        get 'roster_user', params: { course_id: @course.id, id: @student.id }
        expect(assigns['user_data'][:common_contexts]).to be_empty
      end
    end
  end

  describe "POST 'object_snippet'" do
    before(:each) do
      @obj = "<object data='test'></object>"
      allow(HostUrl).to receive(:is_file_host?).and_return(true)
      @data = Base64.encode64(@obj)
      @hmac = Canvas::Security.hmac_sha1(@data)
    end

    it 'requires a valid HMAC' do
      post 'object_snippet', params: { object_data: @data, s: 'DENIED' }
      assert_status(400)
    end

    it 'renders given a correct HMAC' do
      post 'object_snippet', params: { object_data: @data, s: @hmac }
      expect(response).to be_successful
      expect(response['X-XSS-Protection']).to eq '0'
    end
  end

  describe "GET '/media_objects/:id/thumbnail" do
    it 'redirects to kaltura even if the MediaObject does not exist' do
      allow(CanvasKaltura::ClientV3).to receive(:config).and_return({})
      expect_any_instance_of(CanvasKaltura::ClientV3).to receive(:thumbnail_url).and_return(
        'http://example.com/thumbnail_redirect'
      )
      get :media_object_thumbnail, params: { id: '0_notexist', width: 100, height: 100 }

      expect(response).to be_redirect
      expect(response.location).to eq 'http://example.com/thumbnail_redirect'
    end
  end

  describe "POST '/media_objects'" do
    before :each do
      user_session(@student)
    end

    it 'matches the create_media_object route' do
      assert_recognizes(
        { controller: 'context', action: 'create_media_object' },
        { path: 'media_objects', method: :post }
      )
    end

    it 'updates the object if it already exists' do
      @media_object = @user.media_objects.build(media_id: 'new_object')
      @media_object.media_type = 'audio'
      @media_object.title = 'original title'
      @media_object.save

      @original_count = @user.media_objects.count

      post :create_media_object,
           params: {
             context_code: "user_#{@user.id}",
             id: @media_object.media_id,
             type: @media_object.media_type,
             title: 'new title'
           }

      @media_object.reload
      expect(@media_object.title).to eq 'new title'

      @user.reload
      expect(@user.media_objects.count).to eq @original_count
    end

    it "creates the object if it doesn't already exist" do
      @original_count = @user.media_objects.count

      post :create_media_object,
           params: {
             context_code: "user_#{@user.id}", id: 'new_object', type: 'audio', title: 'title'
           }

      @user.reload
      expect(@user.media_objects.count).to eq @original_count + 1
      @media_object = @user.media_objects.last

      expect(@media_object.media_id).to eq 'new_object'
      expect(@media_object.media_type).to eq 'audio'
      expect(@media_object.title).to eq 'title'
    end

    it 'truncates the title and user_entered_title' do
      post :create_media_object,
           params: {
             context_code: "user_#{@user.id}",
             id: 'new_object',
             type: 'audio',
             title: 'x' * 300,
             user_entered_title: 'y' * 300
           }
      @media_object = @user.reload.media_objects.last
      expect(@media_object.title.size).to be <= 255
      expect(@media_object.user_entered_title.size).to be <= 255
    end

    it 'returns the embedded_iframe_url' do
      post :create_media_object,
           params: {
             context_code: "user_#{@user.id}", id: 'new_object', type: 'audio', title: 'title'
           }
      @media_object = @user.reload.media_objects.last
      expect(JSON.parse(response.body)['embedded_iframe_url']).to eq media_object_iframe_path(
        @media_object.media_id
      )
    end
  end

  describe "GET 'prior_users" do
    before do
      user_session(@teacher)
      create_users_in_course(@course, 21)
      @course.student_enrollments.update_all(workflow_state: 'completed')
    end

    it 'paginates' do
      get :prior_users, params: { course_id: @course.id }
      expect(response).to be_successful
      expect(assigns[:prior_users].size).to eql 20
    end
  end

  describe "GET 'undelete_index'" do
    it 'works' do
      user_session(@teacher)
      assignment_model(course: @course)
      @assignment.destroy

      get :undelete_index, params: { course_id: @course.id }
      expect(response).to be_successful
      expect(assigns[:deleted_items]).to include(@assignment)
    end

    it 'shows group_categories' do
      user_session(@teacher)
      category = GroupCategory.student_organized_for(@course)
      category.destroy

      get :undelete_index, params: { course_id: @course.id }
      expect(response).to be_successful
      expect(assigns[:deleted_items]).to include(category)
    end

    it 'shows groups' do
      user_session(@teacher)
      category = GroupCategory.student_organized_for(@course)
      g1 = category.groups.create!(context: @course, name: 'group_a')
      g1.destroy

      get :undelete_index, params: { course_id: @course.id }
      expect(response).to be_successful
      expect(assigns[:deleted_items]).to include(g1)
    end

    describe 'Rubric Associations' do
      before(:once) do
        assignment = assignment_model(course: @course)
        rubric = rubric_model({
                                context: @course,
                                title: 'Test Rubric',
                                data: [{
                                  description: 'Some criterion',
                                  points: 10,
                                  id: 'crit1',
                                  ignore_for_scoring: true,
                                  ratings: [
                                    { description: 'Good', points: 10, id: 'rat1', criterion_id: 'crit1' }
                                  ]
                                }]
                              })
        @association = rubric.associate_with(assignment, @course, purpose: 'grading')
      end

      it 'shows deleted rubric associations' do
        @association.destroy
        user_session(@teacher)
        get :undelete_index, params: { course_id: @course.id }
        expect(assigns[:deleted_items]).to include @association
      end

      it 'does not show active rubric associations' do
        user_session(@teacher)
        get :undelete_index, params: { course_id: @course.id }
        expect(assigns[:deleted_items]).not_to include @association
      end
    end
  end

  describe "POST 'undelete_item'" do
    it 'allows undeleting groups' do
      user_session(@teacher)
      category = GroupCategory.student_organized_for(@course)
      g1 = category.groups.create!(context: @course, name: 'group_a')
      g1.destroy

      post :undelete_item, params: { course_id: @course.id, asset_string: g1.asset_string }
      expect(g1.reload.workflow_state).to eq 'available'
      expect(g1.deleted_at).to be_nil
    end

    it 'allows undeleting group_categories' do
      user_session(@teacher)
      category = GroupCategory.student_organized_for(@course)
      g1 = category.groups.create!(context: @course, name: 'group_a')
      category.destroy

      post :undelete_item, params: { course_id: @course.id, asset_string: category.asset_string }
      expect(category.reload.deleted_at).to be_nil
      expect(g1.reload.deleted_at).to be_nil
      expect(g1.workflow_state).to eq 'available'
    end

    it 'does not allow dangerous sends' do
      user_session(@teacher)
      expect_any_instantiation_of(@course).not_to receive(:teacher_names)
      post :undelete_item, params: { course_id: @course.id, asset_string: 'teacher_name_1' }
      expect(response.status).to eq 500
    end

    it 'allows undeleting a "normal" association' do
      user_session(@teacher)
      assignment_model(course: @course)
      @assignment.destroy

      post :undelete_item, params: { course_id: @course.id, asset_string: @assignment.asset_string }
      expect(@assignment.reload).not_to be_deleted
    end

    it 'allows undeleting wiki pages' do
      user_session(@teacher)
      page = @course.wiki_pages.create!(title: 'some page')
      page.destroy

      post :undelete_item, params: { course_id: @course.id, asset_string: page.asset_string }
      expect(page.reload).not_to be_deleted
      expect(page.current_version).not_to be_nil
    end

    it 'allows undeleting attachments' do
      # attachments are special because they use file_state
      user_session(@teacher)
      attachment_model
      @attachment.destroy

      post :undelete_item, params: { course_id: @course.id, asset_string: @attachment.asset_string }
      expect(@attachment.reload).not_to be_deleted
    end

    it 'allows undeleting rubric associations' do
      assignment = assignment_model(course: @course)
      rubric = rubric_model({
                              context: @course,
                              title: 'Test Rubric',
                              data: [{
                                description: 'Some criterion',
                                points: 10,
                                id: 'crit1',
                                ignore_for_scoring: true,
                                ratings: [
                                  { description: 'Good', points: 10, id: 'rat1', criterion_id: 'crit1' }
                                ]
                              }]
                            })
      association = rubric.associate_with(assignment, @course, purpose: 'grading')
      puts "association id is: #{association.id}"
      association.destroy

      user_session(@teacher)
      post :undelete_item, params: { course_id: @course.id, asset_string: association.asset_string }
      expect(association.reload).not_to be_deleted
    end
  end

  describe "GET 'roster_user_usage'" do
    before(:once) do
      page = @course.wiki_pages.create(title: 'some page')
      AssetUserAccess.create!(
        { user_id: @student, asset_code: page.asset_string, context: @course, category: 'pages' }
      )
    end

    it 'returns accesses' do
      user_session(@teacher)

      get :roster_user_usage, params: { course_id: @course.id, user_id: @student.id }

      expect(response).to be_successful
      expect(assigns[:accesses].length).to eq 1
    end

    it 'returns json' do
      user_session(@teacher)

      get :roster_user_usage, params: { course_id: @course.id, user_id: @student.id }, format: :json

      expect(response).to be_successful
      expect(json_parse(response.body).length).to eq 1
    end
  end
end
