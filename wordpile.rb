require 'yaml'
require 'net/http'
require 'mediawiki_api'

CRED = 'wiki_credentials.yml'
TOOL_PAGE = 'User:Ijon/Wordpile'
REQS_PAGE = 'User:Ijon/Wordpile/Requests'
RESULTS_PAGE = 'User:Ijon/Wordpile/Results'
REQS_SECTION = '===Current requests==='
PAGES_PER_API_CALL = 20

private
def do_wordpile(reqs, cred_hash)
  res = []
  i = 1
  tot = reqs.length

  reqs.each {|r|
    puts "Handling request #{i} out of #{tot}..."
    # grab papepile
    uri = URI("https://tools.wmflabs.org/pagepile/api.php?id=#{r[:pagepile]}&action=get_data&format=json")
    response = Net::HTTP.get(uri)
    resp = JSON.parse(response)
    wiki = resp['wiki']
    arts = resp['pages']
    pos = wiki.index('wiki')
    if pos == nil
      puts "Error parsing wiki name in PagePile ##{r[:pagepile]}!  Dropping this request."
      next
    end
    lang = wiki[0..pos-1]
    proj = wiki[pos..-1]
    proj = 'wikipedia' if proj == 'wiki' # for historical reasons, Wikipedia is just 'wiki' in the database names
    client = MediawikiApi::Client.new "https://#{lang}.#{proj}.org/w/api.php"
    client.log_in(cred_hash['user'], cred_hash['password'])

    # count words
    wordcounts = {}
    apireqs = []
    total = arts.count
    cur_req = ''
    totalwords = 0
    k = 1
    arts.each do |art|
      puts "Querying page #{k} out of #{arts.count}" if k % 20 == 0
      api_result = client.action :parse, page: art, prop: 'text'
      if api_result.nil? or api_result['parse'].nil?
        puts "Error querying API! Dropping this request."
        k += 1
        next
      end
      title = api_result['parse']['title']
      text = api_result['parse']['text']
      unless text.nil?
        wordcounts[title] = word_count(to_plaintext(text.first[1]))
        totalwords += wordcounts[title]
      end
      k += 1
    end
    # sort
    max_item = wordcounts.count > 999 ? 999 : -1

    sorted_counts = wordcounts.sort_by {|_key, value| value}.reverse[0..max_item]

    # store result
    res << {request: r, top100: sorted_counts, total_words: totalwords}
    i += 1
  }
  return res
end

def slurp_requests(mw)
  reqs = []
  attempts = 0
  success = false
  until success do
    begin
      attempts += 1
      reqs_wikitext = mw.get_wikitext(REQS_PAGE).body
      # having grabbed the current page, quickly blank out the reqs section
      mw.edit({title: REQS_PAGE, text: '# ...', summary: 'Wordpile processing requests', bot: 'true'}) # an edit conflict would fail the request # TODO: verify!
    rescue
      # give up
      if attempts > 3
        puts "Failed thrice to grab and update the reqs.  Must be busy.  Giving up this time.  Will get 'em next time! :)"
        exit
      end
      next
    end
    success = true
  end
  req_lines = reqs_wikitext.split("\n")
  req_lines.each {|r|
    r.strip!
    next if (r.empty?) or (r == '# ...') # skip sample line

    captures = r.match(/#\s+(\d+)\s*(.*)/) # 1 = PagePile ID, 2 = username to report to
    next if captures.nil?
    reqs << {pagepile: captures[1], username: captures[2]}
  }
  if reqs.length > 7 # why 7? shall we say, the seven liberal arts?
    remainder = ''
    reqs[7..-1].each {|r| remainder += "# #{r[:pagepile]} #{r[:username]}\n" }
    mw.edit({title: REQS_PAGE, text: remainder+"# ...\n", summary: 'Wordpile requeuing overflow requests for next run', bot: 'true'}) # an edit conflict would fail the request # TODO: verify!
    reqs = reqs[0..6]
  end
  return reqs
end
def word_count(text)
  text.split.size
end
def spew_output(mw, results)
  new_results = ''
  results.each {|r|
    req = r[:request]
    out_page = "Below are the (up to) 1000 pages from [https://tools.wmflabs.org/pagepile/api.php?id=#{req[:pagepile]}&action=get_data&format=html&doit1 PagePile ##{req[:pagepile]}] with the most words in them, in descending order.\n\nIn total, the pages in this PagePile include #{r[:total_words]} words.\n\nThey were created by the [[User:Ijon/Wordpile|Wordpile]] tool.\n\n==Articles by word count==\n{| class=\"wikitable sortable\"\n|-\n! Article\n! word count\n|-\n"
    r[:top100].each {|art|
      out_page += "| #{art[0]} || #{art[1]}\n|-\n"
    }
    out_page += "|}"
    pagename = TOOL_PAGE+"/"+Date.today.year.to_s+"/"+Date.today.month.to_s+"/"+req[:pagepile]
    puts "Posting results subpage at #{pagename}"
    mw.edit({title: pagename, text: out_page, summary: "Wordpile results for PagePile ##{req[:pagepile]}'", bot: 'true'}) # an edit conflict would fail the request # TODO: verify!
    new_results += "# [[#{pagename}|#{req[:pagepile]}]]"
    # notify user
    unless req[:username].nil?
      new_results += " (for [[User:#{req[:username]}|#{req[:username]}]])"
      puts "Notifying user #{req[:username]}"
      mw.edit({title: "User talk:#{req[:username]}", text: "Hullo!\n\n[[User:Ijon/Wordpile|Wordpile]] has just completed a report you asked for, with word-counts for pages from PagePile ##{req[:pagepile]}.\n\nThe report is [[#{pagename}|waiting for you here]]. :)  Please note that the report pages may get '''deleted''' after 60 days, so if you'd like to keep these results around, copy them somewhere else.\n\nYour faithful servant,\n\n~~~~", summary: "Wordpile has completed a report for you! :)", section: "new", bot: 'true'})
    end
    new_results += "\n"
  }
  # now append all the new pages onto the results section, if there are any
  if results.length > 0
    existing_results = mw.get_wikitext(RESULTS_PAGE).body
    puts "posting results to #{RESULTS_PAGE}"
    mw.edit({title: RESULTS_PAGE, text: existing_results + "\n#{Date.today.to_s}\n"+new_results, summary: "Wordpile appending new results", bot: 'true'})
  else
    puts "no results."
  end

end

def to_plaintext(s)
  s.split(/\<.*?\>/)
   .map(&:strip)
   .reject(&:empty?)
   .join(' ')
   .gsub(/\s,/,',')
end

##############################
# main

# read credentials
f = File.open(CRED, 'rb')
if f.nil?
  puts "#{CRED} not found!  Terminating."
  exit
end
cred_hash = YAML::load(f.read) # read DB hash
f.close
# setup
puts "logging in."
mw = MediawikiApi::Client.new('https://meta.wikimedia.org/w/api.php')
mw.log_in(cred_hash['user'], cred_hash['password'])

# input
puts "reading requests."
reqs = slurp_requests(mw)
puts "Found the following requests:"
reqs.each {|r|
  puts "pagepile: #{r[:pagepile]}, username: #{r[:username]}"
}

# crunch!
puts "crunch time!"
results = do_wordpile(reqs, cred_hash)
# output
spew_output(mw, results)
# yalla bye
puts "all done! :)"
