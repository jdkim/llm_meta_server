# Shared admission state. Lock only during bookkeeping, never during inference.
class AnonymousUsageState < ApplicationRecord
  def self.update_atomically
    record = create_or_find_by!(scope: "admission")
    record.with_lock do
      result = yield record.state
      record.save!
      result
    end
  end
end
