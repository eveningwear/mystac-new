require 'pp'

def parse_stats(stat_section)
  stats = {}
  stat_section.split("\n").each { |line|
    line =~ /(.*):\s*([\d\.]*)/
    stats.merge! $1 => $2
  }
end


f = open 'ab.out'

text = f.read
stat_section = text.split("\n\n")[4]
times_section = text.split("\n\n")[5]
stats = parse_stats(stat_section)

pp stats

