# Shared admission state. Lock only during bookkeeping, never during inference.
class AnonymousUsageState < ApplicationRecord
  def self.update_atomically(scope: "admission")
    record = create_or_find_by!(scope: scope)
    record.with_lock do
      result = yield record.state
      record.save!
      result
    end
  end
end
