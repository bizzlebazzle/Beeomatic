-- Storage contract: scan() -> {endpoint,slot,stack}; materialize(item,endpoint)
-- -> physical item; deposit(item,endpoint); counts are always rescanned.
-- Exact source slots are exclusively leased by the scheduler until movement commits.
return {operations={"scan","materialize","deposit","validate"}}
