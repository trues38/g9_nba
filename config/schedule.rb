# Whenever gem configuration for cron jobs
# Deploy with: whenever --update-crontab gate9_sports

set :output, "/var/log/gate9_sports/cron.log"
set :environment, "production"

# Fetch odds and injuries daily at 9 AM KST (0 AM UTC)
every 1.day, at: "0:00 am" do
  rake "nba:fetch_all"
end

# Recalculate schedule edges weekly on Monday
every :monday, at: "1:00 am" do
  rake "nba:calculate_edge"
end

# Update schedule monthly (new games added)
every 1.month, at: "2:00 am" do
  rake "nba:import_schedule"
end
