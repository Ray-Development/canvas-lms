# frozen_string_literal: true

#
# Copyright (C) 2017 - present Instructure, Inc.
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

module Types
  class AssignmentGroupRulesType < ApplicationObjectType
    graphql_name "AssignmentGroupRules"

    alias rules object

    field :drop_lowest, Integer,
          "The lowest N assignments are not included in grade calculations",
          null: true

    field :drop_highest, Integer,
          "The highest N assignments are not included in grade calculations",
          null: true

    field :never_drop, [AssignmentType], null: true
    def never_drop
      if rules[:never_drop].present?
        Loaders::IDLoader.for(Assignment).load_many(rules[:never_drop])
      end
    end
  end
end
