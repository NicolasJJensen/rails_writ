# frozen_string_literal: true

class ApplicationPolicy
  include Writ::PolicyHelpers
  include Conditions

  attr_reader :context, :record

  def initialize(context, record)
    @context = context
    @record = record
  end

  def index?
    permitted?(:read)
  end

  def show?
    permitted?(:read)
  end

  def read?
    permitted?(:read)
  end

  def new?
    permitted?(:create)
  end

  def create?
    permitted?(:create)
  end

  def edit?
    permitted?(:update)
  end

  def update?
    permitted?(:update)
  end

  def destroy?
    permitted?(:delete)
  end

  def delete?
    permitted?(:delete)
  end

  private

  def permitted?(action)
    # Keep Pundit checks on saved-state authorization; proposed changes use Access.validation explicitly.
    Writ::Access.authorization(context: context, action: action, subject: record).allowed?
  end

  class Scope
    attr_reader :scope, :context

    def initialize(context, scope)
      @scope = scope
      @context = context
    end

    def resolve
      Writ::Access.filter(context: context, action: :read, records: scope)
    end
  end
end
